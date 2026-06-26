// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AIJudgeTEE} from "../contracts/AIJudgeTEE.sol";

/// @dev Mock TEE/LLM precompile (0x0802): returns RAW abi.encode(simmedInput, actualOutput)
///      via assembly, matching PrecompileConsumer._executePrecompile.
contract MockTEELLM {
    struct ConvoHistory {
        string a;
        string b;
        string c;
    }
    bool internal immutable HAS_ERROR;

    constructor(bool hasError) {
        HAS_ERROR = hasError;
    }

    function _response() internal view returns (bytes memory) {
        ConvoHistory memory ch;
        bytes memory actualOutput = abi.encode(
            HAS_ERROR,
            bytes('{"winnerIndex":1,"ranking":[{"index":1,"score":94,"reason":"best satisfies rubric"}],"revealedAnswersRef":"ipfs://bundle","revealedAnswersHash":"0x..","summary":"Submission 1 strongest"}'),
            bytes(""),
            HAS_ERROR ? "TEE judge failed" : "",
            ch
        );
        return abi.encode(bytes(""), actualOutput);
    }

    fallback() external {
        bytes memory data = _response();
        assembly {
            return(add(data, 0x20), mload(data))
        }
    }
}

contract AIJudgeTEETest is Test {
    AIJudgeTEE internal judge;
    address internal constant LLM = address(0x0802);

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal base;
    uint256 internal subDeadline;
    uint256 internal bountyId;

    // stand-ins for client-side ECIES ciphertext blobs
    bytes internal ctA = bytes("ENC(alice answer -> TEE pubkey)");
    bytes internal ctB = bytes("ENC(bob answer -> TEE pubkey)");

    function setUp() public {
        judge = new AIJudgeTEE();
        MockTEELLM mock = new MockTEELLM(false);
        vm.etch(LLM, address(mock).code);

        base = 10_000;
        vm.warp(base);
        subDeadline = base + 1_000;

        vm.deal(owner, 10 ether);
        vm.prank(owner);
        bountyId = judge.createBounty{value: 1 ether}(
            "Best idea (private)",
            "Most original, correct answer wins",
            subDeadline
        );
    }

    function _submit(address who, bytes memory ct, string memory ref) internal {
        vm.prank(who);
        judge.submitEncrypted(bountyId, keccak256(ct), ref);
    }

    // --------------------------- submission ----------------------------- //

    function test_Submit_StoresHashAndRef_NoPlaintext() public {
        _submit(alice, ctA, "ipfs://alice");
        (address submitter, bytes32 h, string memory ref) = judge.getSubmission(bountyId, 0);
        assertEq(submitter, alice);
        assertEq(h, keccak256(ctA));
        assertEq(ref, "ipfs://alice");
        // No function exposes plaintext; only hash + DA ref are on-chain.
    }

    function test_Submit_AfterDeadline_Reverts() public {
        vm.warp(subDeadline);
        vm.prank(alice);
        vm.expectRevert(AIJudgeTEE.SubmissionsClosed.selector);
        judge.submitEncrypted(bountyId, keccak256(ctA), "ipfs://alice");
    }

    function test_Submit_Twice_Reverts() public {
        _submit(alice, ctA, "ipfs://alice");
        vm.prank(alice);
        vm.expectRevert(AIJudgeTEE.AlreadySubmitted.selector);
        judge.submitEncrypted(bountyId, keccak256(ctB), "ipfs://alice2");
    }

    function test_Submit_EmptyCiphertext_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(AIJudgeTEE.EmptyCiphertext.selector);
        judge.submitEncrypted(bountyId, bytes32(0), "ipfs://alice");
    }

    function test_Submit_TooMany_Reverts() public {
        for (uint256 i = 0; i < 10; i++) {
            address p = vm.addr(i + 100);
            vm.prank(p);
            judge.submitEncrypted(bountyId, keccak256(abi.encodePacked(i)), "ipfs://x");
        }
        address extra = vm.addr(999);
        vm.prank(extra);
        vm.expectRevert(AIJudgeTEE.TooManySubmissions.selector);
        judge.submitEncrypted(bountyId, keccak256("z"), "ipfs://z");
    }

    // ----------------------------- judging ------------------------------ //

    function test_Judge_WhileOpen_Reverts() public {
        _submit(alice, ctA, "ipfs://alice");
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.SubmissionsOpen.selector);
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    function test_Judge_NotOwner_Reverts() public {
        _submit(alice, ctA, "ipfs://alice");
        vm.warp(subDeadline);
        vm.prank(bob);
        vm.expectRevert(AIJudgeTEE.NotBountyOwner.selector);
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    function test_Judge_NoSubmissions_Reverts() public {
        vm.warp(subDeadline);
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.NoSubmissions.selector);
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    function test_Judge_Success_BatchOverEncrypted() public {
        _submit(alice, ctA, "ipfs://alice");
        _submit(bob, ctB, "ipfs://bob");
        vm.warp(subDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef"); // ONE batched TEE call

        AIJudgeTEE.BountyView memory b = judge.getBounty(bountyId);
        assertTrue(b.judged);
        assertGt(b.aiReview.length, 0);
        assertEq(b.submissionCount, 2);
    }

    function test_Judge_TEEError_Reverts() public {
        MockTEELLM errMock = new MockTEELLM(true);
        vm.etch(LLM, address(errMock).code);
        _submit(alice, ctA, "ipfs://alice");
        vm.warp(subDeadline);
        vm.prank(owner);
        vm.expectRevert(bytes("TEE judge failed"));
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    // ---------------------------- finalize ------------------------------ //

    function test_Finalize_BeforeJudge_Reverts() public {
        _submit(alice, ctA, "ipfs://alice");
        vm.warp(subDeadline);
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.NotJudged.selector);
        judge.finalizeWinner(bountyId, 0, "ipfs://bundle", keccak256("bundle"));
    }

    function test_Finalize_EmptyBundle_Reverts() public {
        _toJudged();
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.EmptyBundle.selector);
        judge.finalizeWinner(bountyId, 0, "ipfs://bundle", bytes32(0));
    }

    function test_Finalize_PaysWinner_AndCommitsBundle() public {
        _submit(alice, ctA, "ipfs://alice");
        _submit(bob, ctB, "ipfs://bob");
        vm.warp(subDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");

        bytes memory bundle = bytes('{"0":"alice answer","1":"bob answer"}');
        bytes32 bundleHash = keccak256(bundle);

        uint256 balBefore = bob.balance;
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 1, "ipfs://revealed-bundle", bundleHash);
        assertEq(bob.balance, balBefore + 1 ether);

        AIJudgeTEE.BountyView memory b = judge.getBounty(bountyId);
        assertTrue(b.finalized);
        assertEq(b.winnerIndex, 1);
        assertEq(b.revealedAnswersHash, bundleHash);
        assertEq(b.reward, 0);

        // anyone can verify the published bundle matches the on-chain hash
        assertTrue(judge.verifyRevealedBundle(bountyId, bundle));
        assertFalse(judge.verifyRevealedBundle(bountyId, bytes("tampered")));
    }

    function test_Finalize_Twice_Reverts() public {
        _toJudgedWithTwo();
        vm.prank(owner);
        judge.finalizeWinner(bountyId, 0, "ipfs://bundle", keccak256("bundle"));
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.AlreadyFinalized.selector);
        judge.finalizeWinner(bountyId, 0, "ipfs://bundle", keccak256("bundle"));
    }

    function test_Finalize_InvalidWinner_Reverts() public {
        _toJudged();
        vm.prank(owner);
        vm.expectRevert(AIJudgeTEE.InvalidWinnerIndex.selector);
        judge.finalizeWinner(bountyId, 5, "ipfs://bundle", keccak256("bundle"));
    }

    // ------------------------------ shared ------------------------------ //

    function _toJudged() internal {
        _submit(alice, ctA, "ipfs://alice");
        vm.warp(subDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");
    }

    function _toJudgedWithTwo() internal {
        _submit(alice, ctA, "ipfs://alice");
        _submit(bob, ctB, "ipfs://bob");
        vm.warp(subDeadline);
        vm.prank(owner);
        judge.judgeAll(bountyId, hex"deadbeef");
    }
}
