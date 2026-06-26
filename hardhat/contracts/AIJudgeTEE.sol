// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title AIJudgeTEE (Ritual-native hidden submissions) — Advanced Track
 * @notice Stronger privacy than commit-reveal: answers are ENCRYPTED to a
 *         Ritual TEE executor and never become public on the submission path.
 *         Plaintext exists in only two places:
 *           1. the participant's client, at encryption time; and
 *           2. inside the TEE enclave, during batch judging.
 *
 *  Compared to commit-reveal (AIJudge.sol), there is NO public reveal phase —
 *  the chain only ever sees ciphertext hashes + storage references. After
 *  judging, the TEE publishes a single "revealed bundle" off-chain (DA), and
 *  the contract records its reference + hash so anyone can verify exactly what
 *  was judged.
 *
 *  On-chain vs off-chain:
 *    - On-chain:  ciphertextHash + ciphertextRef per submission, the AI review,
 *                 the winner, the reward, and revealedAnswersRef/Hash.
 *    - Off-chain: the ciphertext blobs and the final revealed bundle (DA:
 *                 ipfs:// / hf:// / gcs://). Large plaintext is never stored
 *                 on-chain (gas + privacy).
 *
 *  Batch judging: judgeAll submits ONE inference request whose payload carries
 *  all ciphertext references; the TEE fetches + decrypts them inside the
 *  enclave and ranks them together (never one LLM call per answer).
 *
 *  Time units: same note as AIJudge — compares against block.timestamp, which
 *  is in MILLISECONDS on Ritual. Pass deadlines in the matching unit.
 */
contract AIJudgeTEE is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_REF_LENGTH = 256;

    uint256 public nextBountyId = 1;

    struct EncSubmission {
        address submitter;
        bytes32 ciphertextHash; // keccak256 of the encrypted answer blob
        string ciphertextRef; // DA pointer to the ciphertext (ipfs://, hf://, gcs://)
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        bool judged;
        bool finalized;
        bytes aiReview; // raw batched-LLM completion (recommendation only)
        uint256 winnerIndex;
        string revealedAnswersRef; // DA pointer to the post-judging revealed bundle
        bytes32 revealedAnswersHash; // keccak256 of that bundle (verifiable on-chain)
        EncSubmission[] submissions;
        mapping(address => uint256) slot; // 1-based; 0 == none
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 winnerIndex;
        string revealedAnswersRef;
        bytes32 revealedAnswersHash;
        bytes aiReview;
    }

    mapping(uint256 => Bounty) private bounties;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline
    );
    event EncryptedSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 ciphertextHash,
        string ciphertextRef
    );
    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);
    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward,
        string revealedAnswersRef,
        bytes32 revealedAnswersHash
    );

    error RewardRequired();
    error BadDeadline();
    error BountyNotFound();
    error NotBountyOwner();
    error SubmissionsClosed();
    error TooManySubmissions();
    error AlreadySubmitted();
    error RefTooLong();
    error EmptyCiphertext();
    error SubmissionsOpen();
    error AlreadyJudged();
    error AlreadyFinalized();
    error NoSubmissions();
    error NotJudged();
    error InvalidWinnerIndex();
    error EmptyBundle();
    error PaymentFailed();

    modifier bountyExists(uint256 bountyId) {
        if (bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }
    modifier onlyOwner(uint256 bountyId) {
        if (msg.sender != bounties[bountyId].owner) revert NotBountyOwner();
        _;
    }

    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert RewardRequired();
        if (submissionDeadline <= block.timestamp) revert BadDeadline();

        bountyId = nextBountyId++;
        Bounty storage b = bounties[bountyId];
        b.owner = msg.sender;
        b.title = title;
        b.rubric = rubric;
        b.reward = msg.value;
        b.submissionDeadline = submissionDeadline;
        b.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, submissionDeadline);
    }

    /**
     * @notice Submit an ENCRYPTED answer (to the TEE executor's public key).
     *         The chain stores only the ciphertext hash + a DA reference — never
     *         plaintext, so no one can read answers before judging.
     * @param ciphertextHash keccak256 of the ciphertext blob (integrity anchor)
     * @param ciphertextRef  DA pointer where the ciphertext is stored
     */
    function submitEncrypted(
        uint256 bountyId,
        bytes32 ciphertextHash,
        string calldata ciphertextRef
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];
        if (block.timestamp >= b.submissionDeadline) revert SubmissionsClosed();
        if (b.submissions.length >= MAX_SUBMISSIONS) revert TooManySubmissions();
        if (b.slot[msg.sender] != 0) revert AlreadySubmitted();
        if (ciphertextHash == bytes32(0)) revert EmptyCiphertext();
        if (bytes(ciphertextRef).length > MAX_REF_LENGTH) revert RefTooLong();

        b.submissions.push(
            EncSubmission({
                submitter: msg.sender,
                ciphertextHash: ciphertextHash,
                ciphertextRef: ciphertextRef
            })
        );
        uint256 index = b.submissions.length - 1;
        b.slot[msg.sender] = index + 1;

        emit EncryptedSubmitted(bountyId, index, msg.sender, ciphertextHash, ciphertextRef);
    }

    /**
     * @notice Owner triggers ONE batched TEE inference over all encrypted
     *         submissions (after the submission deadline). The TEE decrypts the
     *         answers privately inside the enclave and ranks them together; the
     *         plaintext never appears on-chain. `llmInput` is built off-chain and
     *         carries the ciphertext references + the encrypted decryption secret.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        if (block.timestamp < b.submissionDeadline) revert SubmissionsOpen();
        if (b.judged) revert AlreadyJudged();
        if (b.finalized) revert AlreadyFinalized();
        if (b.submissions.length == 0) revert NoSubmissions();

        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);
        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        require(!hasError, errorMessage);

        b.judged = true;
        b.aiReview = completionData;
        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Human-in-the-loop finalization. The owner ratifies a winner
     *         (the AI only recommends) and records the post-judging revealed
     *         bundle published by the TEE: `revealedAnswersRef` (where the
     *         plaintext answers are now published) and `revealedAnswersHash`
     *         (keccak256 of that bundle). The reward is then paid.
     *
     *         Storing the hash on-chain lets anyone verify that the published
     *         bundle is exactly what the judge saw (see verifyRevealedBundle).
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex,
        string calldata revealedAnswersRef,
        bytes32 revealedAnswersHash
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];
        if (!b.judged) revert NotJudged();
        if (b.finalized) revert AlreadyFinalized();
        if (winnerIndex >= b.submissions.length) revert InvalidWinnerIndex();
        if (revealedAnswersHash == bytes32(0)) revert EmptyBundle();
        if (bytes(revealedAnswersRef).length > MAX_REF_LENGTH) revert RefTooLong();

        // checks-effects-interactions
        b.finalized = true;
        b.winnerIndex = winnerIndex;
        b.revealedAnswersRef = revealedAnswersRef;
        b.revealedAnswersHash = revealedAnswersHash;
        uint256 reward = b.reward;
        b.reward = 0;
        address winner = b.submissions[winnerIndex].submitter;

        (bool ok, ) = payable(winner).call{value: reward}("");
        if (!ok) revert PaymentFailed();

        emit WinnerFinalized(
            bountyId,
            winnerIndex,
            winner,
            reward,
            revealedAnswersRef,
            revealedAnswersHash
        );
    }

    /// @notice Anyone can verify a published revealed-answers bundle matches
    ///         the hash committed on-chain at finalization.
    function verifyRevealedBundle(
        uint256 bountyId,
        bytes calldata bundle
    ) external view bountyExists(bountyId) returns (bool) {
        return keccak256(bundle) == bounties[bountyId].revealedAnswersHash;
    }

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage b = bounties[bountyId];
        return
            BountyView({
                owner: b.owner,
                title: b.title,
                rubric: b.rubric,
                reward: b.reward,
                submissionDeadline: b.submissionDeadline,
                judged: b.judged,
                finalized: b.finalized,
                submissionCount: b.submissions.length,
                winnerIndex: b.winnerIndex,
                revealedAnswersRef: b.revealedAnswersRef,
                revealedAnswersHash: b.revealedAnswersHash,
                aiReview: b.aiReview
            });
    }

    /// @notice Returns the integrity anchor + DA pointer only — never plaintext.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes32 ciphertextHash, string memory ciphertextRef)
    {
        Bounty storage b = bounties[bountyId];
        if (index >= b.submissions.length) revert InvalidWinnerIndex();
        EncSubmission storage s = b.submissions[index];
        return (s.submitter, s.ciphertextHash, s.ciphertextRef);
    }
}
