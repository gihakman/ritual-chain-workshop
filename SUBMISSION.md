# Submission — Privacy-Preserving AI Bounty Judge

## Summary
The workshop AI Bounty Judge made answers public on submission, letting later
participants copy earlier ideas. This submission hides answers during the
submission phase via a **commit-reveal** flow (Required Track) and a
**Ritual-native TEE** flow where answers never go public on the submission path
(Advanced Track). Both are implemented and tested (42 passing tests).

## Deliverables mapped to the rubric

| Rubric category (weight) | Where it's addressed |
|---|---|
| **Commit-reveal correctness (30%)** | `AIJudge.sol`: two deadlines, `submitCommitment`/`revealAnswer` with `keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`, one commitment per address, unrevealed excluded from judging, owner judges only after `revealDeadline`, finalize only after judging. Verified by 27 tests. |
| **Smart contract safety (20%)** | Custom errors, `onlyOwner`/`bountyExists` guards, checks-effects-interactions in payout (`reward=0` before transfer), winner must be revealed, single payout, no reentrancy surface. |
| **Ritual understanding (20%)** | One **batch** judging call (no per-answer loop); `ADVANCED.md` explains TEE-backed execution, encrypted inputs, and the on/off-chain split; human-in-the-loop finalization. |
| **Code clarity (15%)** | Documented phases, named errors/events, `BountyView` struct return, focused functions. |
| **Testing / explanation (15%)** | 27 + 15 = 42 forge tests covering valid + invalid reveal cases and full lifecycle; test plan below. |

## Test plan & results

Run: `cd hardhat && pnpm install && forge test` → **42 passed, 0 failed**.

**Commit-reveal (`hardhat/test/AIJudge.t.sol`, 27):** create-bounty guards (bad deadlines, no reward); commit stores only a hash (no plaintext); commit after deadline / twice / over the cap rejected; reveal valid; reveal rejected for wrong salt, wrong answer, wrong sender, wrong bountyId, before window, after window, no commitment, double reveal; judge rejected before reveal deadline / by non-owner / with zero reveals; judge success runs one batch over revealed-only and stores `revealedAnswersHash`; LLM-error path reverts; `revealedAnswersHash` excludes unrevealed answers; finalize rejected before judging / by non-owner / for an unrevealed or invalid winner / twice; finalize pays the winner and zeroes the reward.

**Advanced TEE (`hardhat/test/AIJudgeTEE.t.sol`, 15):** encrypted submit stores hash+ref only (no plaintext); submit after deadline / twice / empty ciphertext / over cap rejected; judge while open / by non-owner / with no submissions rejected; judge success runs one batch over encrypted set; TEE-error path reverts; finalize before judge / empty bundle / invalid winner / twice rejected; finalize pays winner, commits `revealedAnswersRef`+`revealedAnswersHash`, and `verifyRevealedBundle` confirms the published bundle (and rejects a tampered one).

## Architecture note (short)
Commit-reveal is a trustless, any-EVM baseline: only a hash is public during
submission, so copying is impossible, but answers do become public during the
reveal phase before the AI judges them. The Ritual-native TEE design removes
even that exposure — answers are encrypted to the executor and decrypted only
inside the enclave for one batched ranking, then published as a hash-anchored
bundle. Both share the same integrity anchor (`revealedAnswersHash`) and the
same rule that a **human** authorizes the payout while the **AI only
recommends**. Full comparison and diagram in `ADVANCED.md`.

## Frontend changes (in `web/`)
The contract API changed, so the dapp needs: (1) two deadlines in
`CreateBountyForm`; (2) a commit action that computes
`keccak256(abi.encodePacked(answer, salt, address, bountyId))` client-side
(viem `encodePacked` + `keccak256`) and stores the salt locally; (3) a reveal
action enabled only between the deadlines; (4) `parseBounty`/`getSubmission`
decoding updated for the new tuple/struct (`commitment`, `revealed`, two
deadlines); (5) deadlines handled in **milliseconds** on Ritual.

## Reflection — what should be public, hidden, AI-decided vs human-decided
In a bounty system the *rules and commitments* should be public: the rubric,
the reward, the deadlines, who participated, and a tamper-proof hash of each
answer all belong on-chain so the process is auditable and the owner cannot
move the goalposts after seeing entries. What must stay *hidden* is the content
of each answer during submission, because public answers let later entrants
copy and marginally improve earlier ones — unfair when only one person can win.
After judging, the answers (or a hash-anchored bundle of them) should become
public so the outcome can be independently verified. *AI* is well suited to the
labor-intensive comparative work: reading every revealed answer against the
rubric and producing a ranked, reasoned recommendation in a single batch
evaluation. But the AI's output is a recommendation, not an authority — it can
be steered by prompt injection inside submissions, can hallucinate, and cannot
be held accountable. Therefore a *human* (the bounty owner) should make the
final, money-moving decision: ratifying or overriding the AI's pick and
triggering payout. That split keeps the system efficient (AI reads) while
keeping it safe and accountable (a person authorizes funds).
