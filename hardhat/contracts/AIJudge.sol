// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/**
 * @title AIJudge (Commit-Reveal Bounty)
 * @notice Privacy-preserving AI bounty judge.
 *
 *  Workshop weakness fixed: in the original contract `submitAnswer` stored the
 *  answer as PLAINTEXT on-chain, so later participants could read and copy
 *  earlier answers before judging. This version hides answers during the
 *  submission phase using a commit-reveal scheme:
 *
 *    createBounty ──► COMMIT (hash only) ──► REVEAL (answer + salt)
 *                 ──► JUDGE (one batch LLM call) ──► FINALIZE (pay winner)
 *
 *  Only the commitment hash is public during submission. Real answers are
 *  revealed (and only then stored) after the submission deadline, and only
 *  valid reveals are eligible for AI judging.
 *
 *  NOTE on time units: the contract is unit-agnostic — it only compares
 *  `block.timestamp` against the deadlines you pass in. On Ritual,
 *  `block.timestamp` is expressed in MILLISECONDS, so pass millisecond
 *  deadlines there; on a seconds-based EVM chain, pass seconds. Keep the
 *  contract and the client on the same unit.
 */
contract AIJudge is PrecompileConsumer {
    // --------------------------------------------------------------------- //
    //                               Constants                               //
    // --------------------------------------------------------------------- //

    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    // --------------------------------------------------------------------- //
    //                                 Types                                 //
    // --------------------------------------------------------------------- //

    struct Submission {
        address submitter;
        bytes32 commitment; // keccak256(abi.encodePacked(answer, salt, submitter, bountyId))
        bool revealed;
        string answer; // empty until a valid reveal
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commits allowed strictly before this
        uint256 revealDeadline; // reveals allowed in [submissionDeadline, revealDeadline)
        bool judged;
        bool finalized;
        bytes aiReview; // raw LLM completion bytes from the batch judging call
        bytes32 revealedAnswersHash; // on-chain commitment to exactly what was judged
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
        // 1-based index into `submissions` for each participant (0 == no commitment)
        mapping(address => uint256) commitmentSlot;
    }

    // Mirrors the Ritual LLM precompile's ConvoHistory tail field.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // Flattened, read-only view of a bounty (returned as a single memory struct
    // to keep `getBounty` within the EVM stack limit and easy to consume).
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        uint256 submissionCount;
        uint256 revealedCount;
        uint256 winnerIndex;
        bytes32 revealedAnswersHash;
        bytes aiReview;
    }

    // `bounties` is private because a struct containing a mapping cannot have
    // an auto-generated public getter; explicit getters are provided below.
    mapping(uint256 => Bounty) private bounties;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(
        uint256 indexed bountyId,
        bytes32 revealedAnswersHash,
        uint256 revealedCount,
        bytes aiReview
    );

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // --------------------------------------------------------------------- //
    //                                Errors                                 //
    // --------------------------------------------------------------------- //

    error RewardRequired();
    error BadDeadlines();
    error BountyNotFound();
    error NotBountyOwner();
    error SubmissionsClosed();
    error TooManySubmissions();
    error AlreadyCommitted();
    error AnswerTooLong();
    error NotInRevealWindow();
    error NoCommitment();
    error AlreadyRevealed();
    error InvalidReveal();
    error RevealNotOver();
    error AlreadyJudged();
    error AlreadyFinalized();
    error NoRevealedAnswers();
    error NotJudged();
    error InvalidWinnerIndex();
    error WinnerNotRevealed();
    error PaymentFailed();

    // --------------------------------------------------------------------- //
    //                               Modifiers                               //
    // --------------------------------------------------------------------- //

    modifier bountyExists(uint256 bountyId) {
        if (bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        if (msg.sender != bounties[bountyId].owner) revert NotBountyOwner();
        _;
    }

    // --------------------------------------------------------------------- //
    //                             Bounty creation                           //
    // --------------------------------------------------------------------- //

    /**
     * @notice Create a bounty and escrow the reward (msg.value).
     * @param submissionDeadline Commits accepted strictly before this time.
     * @param revealDeadline     Reveals accepted in [submissionDeadline, revealDeadline).
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert RewardRequired();
        // submission window must be open now and reveal must come strictly after it
        if (
            submissionDeadline <= block.timestamp ||
            revealDeadline <= submissionDeadline
        ) revert BadDeadlines();

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    // --------------------------------------------------------------------- //
    //                          Phase 1: commitment                          //
    // --------------------------------------------------------------------- //

    /**
     * @notice Submit a commitment hash (no plaintext on-chain). One per address.
     * @param commitment keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (block.timestamp >= bounty.submissionDeadline) revert SubmissionsClosed();
        if (bounty.submissions.length >= MAX_SUBMISSIONS) revert TooManySubmissions();
        if (bounty.commitmentSlot[msg.sender] != 0) revert AlreadyCommitted();

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );
        uint256 index = bounty.submissions.length - 1;
        bounty.commitmentSlot[msg.sender] = index + 1; // store as 1-based

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    // --------------------------------------------------------------------- //
    //                            Phase 2: reveal                            //
    // --------------------------------------------------------------------- //

    /**
     * @notice Reveal a previously committed answer. Valid only if
     *         keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         equals the stored commitment.
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (
            block.timestamp < bounty.submissionDeadline ||
            block.timestamp >= bounty.revealDeadline
        ) revert NotInRevealWindow();
        if (bytes(answer).length > MAX_ANSWER_LENGTH) revert AnswerTooLong();

        uint256 slot = bounty.commitmentSlot[msg.sender];
        if (slot == 0) revert NoCommitment();

        Submission storage submission = bounty.submissions[slot - 1];
        if (submission.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        if (expected != submission.commitment) revert InvalidReveal();

        submission.revealed = true;
        submission.answer = answer;
        unchecked {
            bounty.revealedCount++;
        }

        emit AnswerRevealed(bountyId, slot - 1, msg.sender);
    }

    // --------------------------------------------------------------------- //
    //                         Phase 3: batch judging                        //
    // --------------------------------------------------------------------- //

    /**
     * @notice Owner triggers a SINGLE batched LLM inference over all revealed
     *         answers (never one call per answer). Callable only after the
     *         reveal deadline. The caller builds `llmInput` off-chain from the
     *         revealed answers; the contract additionally records an on-chain
     *         hash of the exact revealed set it expects to have been judged.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (block.timestamp < bounty.revealDeadline) revert RevealNotOver();
        if (bounty.judged) revert AlreadyJudged();
        if (bounty.finalized) revert AlreadyFinalized();
        if (bounty.revealedCount == 0) revert NoRevealedAnswers();

        // One batch inference call.
        bytes memory output = _executePrecompile(LLM_INFERENCE_PRECOMPILE, llmInput);

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;
        bounty.revealedAnswersHash = _hashRevealed(bounty);

        emit AllAnswersJudged(
            bountyId,
            bounty.revealedAnswersHash,
            bounty.revealedCount,
            completionData
        );
    }

    /// @dev Canonical hash of the revealed set: commits the contract to exactly
    ///      which (index, submitter, answer) tuples were eligible at judging.
    function _hashRevealed(
        Bounty storage bounty
    ) private view returns (bytes32) {
        bytes memory buf;
        uint256 len = bounty.submissions.length;
        for (uint256 i = 0; i < len; i++) {
            Submission storage s = bounty.submissions[i];
            if (s.revealed) {
                buf = abi.encodePacked(buf, i, s.submitter, bytes(s.answer));
            }
        }
        return keccak256(buf);
    }

    // --------------------------------------------------------------------- //
    //                       Phase 4: human finalization                     //
    // --------------------------------------------------------------------- //

    /**
     * @notice Owner ratifies the winner (human-in-the-loop) and the reward is
     *         paid. The AI only *recommends*; payout is never automatic.
     *         Winner must be a revealed submission.
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        if (!bounty.judged) revert NotJudged();
        if (bounty.finalized) revert AlreadyFinalized();
        if (winnerIndex >= bounty.submissions.length) revert InvalidWinnerIndex();
        if (!bounty.submissions[winnerIndex].revealed) revert WinnerNotRevealed();

        // checks-effects-interactions
        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;
        uint256 reward = bounty.reward;
        bounty.reward = 0;
        address winner = bounty.submissions[winnerIndex].submitter;

        (bool ok, ) = payable(winner).call{value: reward}("");
        if (!ok) revert PaymentFailed();

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // --------------------------------------------------------------------- //
    //                                Views                                  //
    // --------------------------------------------------------------------- //

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory) {
        Bounty storage bounty = bounties[bountyId];
        return
            BountyView({
                owner: bounty.owner,
                title: bounty.title,
                rubric: bounty.rubric,
                reward: bounty.reward,
                submissionDeadline: bounty.submissionDeadline,
                revealDeadline: bounty.revealDeadline,
                judged: bounty.judged,
                finalized: bounty.finalized,
                submissionCount: bounty.submissions.length,
                revealedCount: bounty.revealedCount,
                winnerIndex: bounty.winnerIndex,
                revealedAnswersHash: bounty.revealedAnswersHash,
                aiReview: bounty.aiReview
            });
    }

    /**
     * @notice Submission view. Before a valid reveal, `answer` is empty — the
     *         plaintext is simply not on-chain yet (that is the whole point).
     */
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, bytes32 commitment, bool revealed, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];
        if (index >= bounty.submissions.length) revert InvalidWinnerIndex();
        Submission storage s = bounty.submissions[index];
        return (s.submitter, s.commitment, s.revealed, s.answer);
    }

    /// @notice Helper so clients can locate their own submission slot.
    function commitmentIndexOf(
        uint256 bountyId,
        address participant
    ) external view bountyExists(bountyId) returns (bool exists, uint256 index) {
        uint256 slot = bounties[bountyId].commitmentSlot[participant];
        return (slot != 0, slot == 0 ? 0 : slot - 1);
    }
}
