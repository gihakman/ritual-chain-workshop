# Advanced Track — Ritual-Native Hidden Submissions (Design + Implementation)

Implemented in [`hardhat/contracts/AIJudgeTEE.sol`](hardhat/contracts/AIJudgeTEE.sol), tested in `hardhat/test/AIJudgeTEE.t.sol` (15 passing cases).

The commit-reveal design (Required Track) has one residual weakness: **answers become public during the reveal phase, before the AI judges them.** The Ritual-native design closes that gap — answers are encrypted to a TEE executor and the plaintext is *never* exposed on the public submission path. It only exists inside the enclave during judging, and afterward in a hash-anchored revealed bundle.

## Private submission flow

```
 Participant (browser)                 Chain (public)                 Ritual TEE executor + DA
 ─────────────────────                 ──────────────                 ────────────────────────
 answer (plaintext)
   │  ECIES-encrypt to
   │  executor TEE pubkey
   ▼
 ciphertext ──put──► DA (ipfs/hf/gcs) ─────────────────────────────────────► stored off-chain
   │                                   submitEncrypted(
   │  keccak256(ciphertext)            bountyId,
   └────────────────────────────────► ciphertextHash,  ── stored ──► EncSubmission{hash, ref}
                                       ciphertextRef)                 (NO plaintext on-chain)

                 ── after submissionDeadline ──

 owner ── judgeAll(bountyId, llmInput) ─► AIJudgeTEE ── 0x0802 ─►  TEE enclave:
                                          (one batch call)          1. fetch all ciphertexts (refs)
                                                                    2. decrypt with sealed key
                                                                    3. run ONE ranking prompt
                                          aiReview ◄── completion ── 4. publish revealed bundle ►DA
                                          (recommendation)

 owner ── finalizeWinner(bountyId, winnerIndex,
                         revealedAnswersRef,        ─► store ref + hash, pay winner
                         revealedAnswersHash) ─────►   anyone: verifyRevealedBundle(bundle)
```

## Required design answers

**Where do plaintext answers exist, and who can read them?**
Plaintext exists in exactly two places: (1) the participant's own client at encryption time, and (2) inside the TEE enclave during `judgeAll`. No one else — not other participants, not the bounty owner, not a chain observer — can read an answer before judging. After judging, the answers are published together as one bundle so the result is auditable.

**What is stored on-chain vs off-chain?**

| | On-chain (`AIJudgeTEE`) | Off-chain (DA: ipfs/hf/gcs) |
|---|---|---|
| Per submission | `ciphertextHash` (integrity), `ciphertextRef` (pointer), `submitter` | the ciphertext blob |
| Judging | `aiReview` (recommendation), `submissionDeadline`, flags | — |
| Final reveal | `revealedAnswersRef`, `revealedAnswersHash`, `winnerIndex`, reward | the revealed-answers bundle |

Large plaintext is **never** stored on-chain (gas + privacy). Only fixed-size hashes and short DA references are.

**How does the LLM receive all submissions together?**
`judgeAll` makes a **single** batched inference request (`llmInput` carries all ciphertext references plus the encrypted decryption secret). The TEE fetches and decrypts every submission inside the enclave and ranks them in one prompt. There is **never** one LLM call per answer — the contract has no per-submission loop calling the precompile.

**How does the final reveal happen, and how does the contract commit to it?**
After judging, the TEE publishes the decrypted answers as one bundle to DA. At `finalizeWinner`, the owner records `revealedAnswersRef` (where to read it) and `revealedAnswersHash = keccak256(bundle)`. Because the hash is stored on-chain, anyone can call `verifyRevealedBundle(bountyId, bundle)` and confirm the published bundle is exactly what was judged — no silent substitution is possible.

## How this uses Ritual for more than "just an LLM call"
- **TEE-backed execution:** judging runs where private inputs are visible to the model but hidden from the public chain.
- **Encrypted inputs/secrets:** answers are ECIES-encrypted to the executor's public key (from `TEEServiceRegistry`); the storage/decryption credential is passed as an encrypted secret, never as plaintext on-chain.
- **Batch judging:** all submissions are compared in one request.
- **Human-in-the-loop:** the AI recommends a winner; the owner authorizes the payout.

## Commit-Reveal vs Ritual-native TEE

| | Commit-Reveal (`AIJudge`) | Ritual-native TEE (`AIJudgeTEE`) |
|---|---|---|
| Portability | Any EVM chain | Requires Ritual TEE precompiles |
| Hidden during submission? | ✅ (only a hash is public) | ✅ (only a hash + ref) |
| Hidden *during judging*? | ❌ answers are public after reveal, before judging | ✅ plaintext only inside the enclave |
| Liveness assumption | Participants must come back to reveal | No reveal step required from participants |
| Trust | Trustless (pure hashing) | Trust the TEE attestation |
| Plaintext on-chain | After reveal (bounded) | Never (only hashes/refs) |
| Output integrity | `revealedAnswersHash` of revealed set | `revealedAnswersHash` of published bundle + `verifyRevealedBundle` |

**Takeaway:** commit-reveal is the simple, fully-trustless baseline that works anywhere but leaks answers before judging; the Ritual-native TEE design keeps answers private end-to-end at the cost of trusting the enclave. They share the same on-chain integrity anchor (`revealedAnswersHash`) and the same human-in-the-loop payout.
