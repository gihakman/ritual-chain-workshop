// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudge} from "../contracts/AIJudge.sol";

/// @dev Mock for the Ritual LLM inference precompile (0x0802).
///      The real precompile returns RAW bytes == abi.encode(simmedInput, actualOutput),
///      so we return raw bytes via assembly (no extra ABI wrapping) to match
///      exactly what PrecompileConsumer._executePrecompile expects.
contract MockLLM {
    bool internal immutable HAS_ERROR;
    constructor(bool hasError) {
        HAS_ERROR = hasError;
    }

    function _response() internal view returns (bytes memory) {
        AIJudge.ConvoHistory memory ch = AIJudge.ConvoHistory("", "", "");
        bytes memory actualOutput = abi.encode(
            HAS_ERROR,
            bytes('{"winnerIndex":0,"ranking":[{"index":0,"score":91}],"summary":"ok"}'),
            bytes(""),
            HAS_ERROR ? "LLM failed" : "",
            ch
        );
        // (bytes simmedInput, bytes actualOutput)
        return abi.encode(bytes(""), actualOutput);
    }

    fallback() external {
        bytes memory data = _response();
        assembly {
            return(add(data, 0x20), mload(data))
        }
    }
}

contract AIJudgeTest is Test {
    AIJudge internal judge;
    address internal constant LLM = address(0x0802);

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal base;
    uint256 internal subDeadline;
    uint256 internal revDeadline;
    uint256 internal bountyId;

    bytes32 internal constant SALT_A = keccak256("alice-salt");
    bytes32 internal constant SALT_B = keccak256("bob-salt");
    string internal constant ANS_A = "Alice's brilliant answer";
    string internal constant ANS_B = "Bob's competing answer";

    function setUp() public {
        judge = new AIJudge();

        // install the (success) LLM mock at the precompile address
        MockLLM mock = new MockLLM(false);
        vm.etch(LLM, address(mock).code);

        base = 10_000;
        vm.warp(base);
        subDeadline = base + 1_000;
        revDeadline = base + 2_000;

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        bountyId = judge.createBounty{value: 1 ether}(
            "Best idea",
            "Most original, correct answer wins",
            subDeadline,
            revDeadline
        );
    }

    // ----------------------------- helpers ------------------------------ //

    function _commitHash(
        string memory answer,
        bytes32 salt,
        address sender,
        uint256 id
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, sender, id));
    }

    function _commit(address who, string memory ans, bytes32 salt) internal {
        vm.prank(who);
        judge.submitCommitment(bountyId, _commitHash(ans, salt, who, bountyId));
    }

    function _reveal(address who, string memory ans, bytes32 salt) internal {
        vm.prank(who);
        judge.revealAnswer(bountyId, ans, salt);
    }

    // ------------------------- creation guards -------------------------- //

    function test_CreateBounty_BadDeadlines_Reverts() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(AIJudge.BadDeadlines.selector);
        judge.createBounty{value: 1 ether}("t", "r", base - 1, base + 5); // sub in past
        vm.prank(owner);
        vm.expectRevert(AIJudge.BadDeadlines.selector);
        judge.createBounty{value: 1 ether}("t", "r", subDeadline, subDeadline); // reveal !> sub
    }

    function test_CreateBounty_NoReward_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(AIJudge.RewardRequired.selector);
        judge.createBounty{value: 0}("t", "r", subDeadline, revDeadline);
    }

    // --------------------------- commit phase --------------------------- //

    function test_Commit_StoresOnlyHash_NoPlaintext() public {
        _commit(alice, ANS_A, SALT_A);
        (address submitter, bytes32 commitment, bool revealed, string memory ans) =
            judge.getSubmission(bountyId, 0);
        assertEq(submitter, alice);
        assertEq(commitment, _commitHash(ANS_A, SALT_A, alice, bountyId));
        assertFalse(revealed);
        assertEq(bytes(ans).length, 0, "answer must be hidden pre-reveal");
    }

    function test_Commit_AfterDeadline_Reverts() public {
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.SubmissionsClosed.selector);
        judge.submitCommitment(bountyId, _commitHash(ANS_A, SALT_A, alice, bountyId));
    }

    function test_Commit_Twice_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.prank(alice);
        vm.expectRevert(AIJudge.AlreadyCommitted.selector);
        judge.submitCommitment(bountyId, _commitHash("other", SALT_A, alice, bountyId));
    }

    function test_Commit_TooMany_Reverts() public {
        for (uint256 i = 0; i < 10; i++) {
            address p = vm.addr(i + 100);
            vm.prank(p);
            judge.submitCommitment(bountyId, _commitHash("a", SALT_A, p, bountyId));
        }
        address extra = vm.addr(999);
        vm.prank(extra);
        vm.expectRevert(AIJudge.TooManySubmissions.selector);
        judge.submitCommitment(bountyId, _commitHash("a", SALT_A, extra, bountyId));
    }

    // --------------------------- reveal phase --------------------------- //

    function test_Reveal_Valid() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        (, , bool revealed, string memory ans) = judge.getSubmission(bountyId, 0);
        assertTrue(revealed);
        assertEq(ans, ANS_A);
        AIJudge.BountyView memory b = judge.getBounty(bountyId);
        assertEq(b.revealedCount, 1);
    }

    function test_Reveal_BeforeWindow_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.prank(alice); // still before submissionDeadline
        vm.expectRevert(AIJudge.NotInRevealWindow.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_A);
    }

    function test_Reveal_AfterWindow_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotInRevealWindow.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_A);
    }

    function test_Reveal_WrongSalt_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.InvalidReveal.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_B);
    }

    function test_Reveal_WrongAnswer_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.InvalidReveal.selector);
        judge.revealAnswer(bountyId, "tampered answer", SALT_A);
    }

    /// @dev Sender-binding: a commitment computed for Alice cannot be revealed by Bob.
    function test_Reveal_WrongSender_Reverts() public {
        bytes32 aliceCommit = _commitHash(ANS_A, SALT_A, alice, bountyId);
        vm.prank(bob); // bob registers Alice's commitment under his own slot
        judge.submitCommitment(bountyId, aliceCommit);
        vm.warp(subDeadline);
        vm.prank(bob); // contract recomputes with msg.sender = bob -> mismatch
        vm.expectRevert(AIJudge.InvalidReveal.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_A);
    }

    /// @dev bountyId-binding: a commitment bound to another bountyId fails to reveal here.
    function test_Reveal_WrongBountyId_Reverts() public {
        bytes32 wrongIdCommit = _commitHash(ANS_A, SALT_A, alice, bountyId + 1);
        vm.prank(alice);
        judge.submitCommitment(bountyId, wrongIdCommit);
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.InvalidReveal.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_A);
    }

    function test_Reveal_NoCommitment_Reverts() public {
        vm.warp(subDeadline);
        vm.prank(bob);
        vm.expectRevert(AIJudge.NoCommitment.selector);
        judge.revealAnswer(bountyId, ANS_B, SALT_B);
    }

    function test_Reveal_Double_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.prank(alice);
        vm.expectRevert(AIJudge.AlreadyRevealed.selector);
        judge.revealAnswer(bountyId, ANS_A, SALT_A);
    }

    // --------------------------- judge phase ---------------------------- //

    function test_Judge_BeforeRevealDeadline_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.prank(owner);
        vm.expectRevert(AIJudge.RevealNotOver.selector);
        judge.judgeAll(bountyId, hex"00");
    }

    function test_Judge_NotOwner_Reverts() public {
        vm.warp(revDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudge.NotBountyOwner.selector);
        judge.judgeAll(bountyId, hex"00");
    }

    function test_Judge_NoReveals_Reverts() public {
        _commit(alice, ANS_A, SALT_A); // committed but never revealed
        vm.warp(revDeadline);
        vm.prank(owner);
        vm.expectRevert(AIJudge.NoRevealedAnswers.selector);
        judge.judgeAll(bountyId, hex"00");
    }

    function test_Judge_Success_BatchOverRevealedOnly() public {
        _commit(alice, ANS_A, SALT_A);
        _commit(bob, ANS_B, SALT_B);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        _reveal(bob, ANS_B, SALT_B);
        vm.warp(revDeadline);

        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef"); // single batch call

        AIJudge.BountyView memory b = judge.getBounty(bountyId);
        assertTrue(b.judged);
        assertEq(b.revealedCount, 2);
        assertGt(b.aiReview.length, 0, "aiReview stored");
        assertTrue(b.revealedAnswersHash != bytes32(0), "revealed bundle committed");
    }

    function test_Judge_Twice_Reverts() public {
        _fullToJudged();
        vm.prank(owner);
        vm.expectRevert(AIJudge.AlreadyJudged.selector);
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    function test_Judge_LLMError_Reverts() public {
        // swap in an error-returning mock
        MockLLM errMock = new MockLLM(true);
        vm.etch(LLM, address(errMock).code);
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("LLM failed"));
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    /// @dev Unrevealed submissions are excluded from the judged bundle hash.
    function test_RevealedAnswersHash_ExcludesUnrevealed() public {
        _commit(alice, ANS_A, SALT_A);
        _commit(bob, ANS_B, SALT_B); // bob never reveals
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");

        AIJudge.BountyView memory b = judge.getBounty(bountyId);
        bytes32 expected = keccak256(
            abi.encodePacked(uint256(0), alice, bytes(ANS_A))
        );
        assertEq(b.revealedAnswersHash, expected, "only Alice in bundle");
        assertEq(b.revealedCount, 1);
    }

    // -------------------------- finalize phase -------------------------- //

    function test_Finalize_BeforeJudge_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        vm.expectRevert(AIJudge.NotJudged.selector);
        judge.finalizeWinner(bountyId, 0);
    }

    function test_Finalize_NotOwner_Reverts() public {
        _fullToJudged();
        vm.prank(bob);
        vm.expectRevert(AIJudge.NotBountyOwner.selector);
        judge.finalizeWinner(bountyId, 0);
    }

    function test_Finalize_WinnerNotRevealed_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        _commit(bob, ANS_B, SALT_B); // bob committed, never revealed -> index 1
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");
        vm.prank(owner);
        vm.expectRevert(AIJudge.WinnerNotRevealed.selector);
        judge.finalizeWinner(bountyId, 1);
    }

    function test_Finalize_PaysWinner() public {
        _commit(alice, ANS_A, SALT_A);
        _commit(bob, ANS_B, SALT_B);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        _reveal(bob, ANS_B, SALT_B);
        vm.warp(revDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");

        uint256 balBefore = bob.balance;
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 1); // bob is index 1
        assertEq(bob.balance, balBefore + 1 ether);

        AIJudge.BountyView memory b = judge.getBounty(bountyId);
        assertTrue(b.finalized);
        assertEq(b.winnerIndex, 1);
        assertEq(b.reward, 0);
    }

    function test_Finalize_Twice_Reverts() public {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0);
        vm.prank(owner);
        vm.expectRevert(AIJudge.AlreadyFinalized.selector);
        judge.finalizeWinner(bountyId, 0);
    }

    // ------------------------------ shared ------------------------------ //

    function _fullToJudged() internal {
        _commit(alice, ANS_A, SALT_A);
        vm.warp(subDeadline);
        _reveal(alice, ANS_A, SALT_A);
        vm.warp(revDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");
    }
}
