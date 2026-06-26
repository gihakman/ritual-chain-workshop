# Privacy-Preserving AI Bounty Judge

Extends the workshop AI Bounty Judge so that **submissions stay hidden until judging is complete**, removing the original flaw where answers were public the moment they were submitted (letting later participants copy and improve on earlier ideas).

Two tracks are delivered and both are implemented + tested:

| Track | Contract | Idea |
|-------|----------|------|
| **Required** — Commit-Reveal | [`hardhat/contracts/AIJudge.sol`](hardhat/contracts/AIJudge.sol) | Participants post only a hash during submission; reveal answer+salt after the deadline. Works on any EVM chain. |
| **Advanced** — Ritual-native TEE | [`hardhat/contracts/AIJudgeTEE.sol`](hardhat/contracts/AIJudgeTEE.sol) | Answers are encrypted to a Ritual TEE executor and never go public on the submission path; the enclave decrypts only during batch judging. |

## 🟢 Live on Ritual testnet (chain 1979)

Both contracts are deployed and a **real commit→reveal cycle was executed on-chain** (not mocked):

| Contract | Address |
|----------|---------|
| `AIJudge` (commit-reveal) | [`0x3e1aC2CCb7F4A63cC88E396a6b1719D865dc2F7c`](https://explorer.ritualfoundation.org/address/0x3e1aC2CCb7F4A63cC88E396a6b1719D865dc2F7c) |
| `AIJudgeTEE` (advanced) | [`0xBF337DEf0fb03B030Db196F480f9A90EC2ef9B68`](https://explorer.ritualfoundation.org/address/0xBF337DEf0fb03B030Db196F480f9A90EC2ef9B68) |

Live commit-reveal proof — bounty #1 on `AIJudge`:
- `createBounty` → `0xc12bab4367f5f367a96aa3009ebea8fdf8638198c4960244909cdeefbde688dc`
- `submitCommitment` → `0xeba6be30017c70721ccd70874585ec6d7450deca18c1e00f5c147d1d1e5d374e` — on-chain answer was `""` (hidden)
- `revealAnswer` → `0x21419485480859cbdba0a6f49895dcca39bba80a8ffe1fafef51b4606bd58c77` — answer revealed and verified on-chain

Reproduce: `DEPLOYER_PRIVATE_KEY=0x… node hardhat/scripts/demo-commit-reveal.mjs`.
Deploy yourself: `cd hardhat && forge create --rpc-url https://rpc.ritualfoundation.org --private-key 0x… contracts/AIJudge.sol:AIJudge --broadcast`.

## New bounty lifecycle (Required Track)

```
createBounty ──► COMMIT (hash only) ──► REVEAL (answer + salt) ──► JUDGE (1 batch LLM call) ──► FINALIZE (human pays winner)
              submissionDeadline ▲            revealDeadline ▲
              commits before ────┘            reveals between the two deadlines
```

1. **Create** — `createBounty(title, rubric, submissionDeadline, revealDeadline)` escrows the reward (`msg.value`).
2. **Commit** (before `submissionDeadline`) — `submitCommitment(bountyId, commitment)` where
   `commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
   Only the hash is on-chain; the answer stays private. One commitment per address.
3. **Reveal** (between `submissionDeadline` and `revealDeadline`) — `revealAnswer(bountyId, answer, salt)`.
   The contract recomputes the hash and requires it to match. Only valid reveals are eligible.
   Binding to `msg.sender` + `bountyId` stops anyone replaying or front-running someone else's reveal.
4. **Judge** (after `revealDeadline`) — `judgeAll(bountyId, llmInput)` runs **one** batched LLM inference over the revealed answers (never one call per answer) and records `revealedAnswersHash`, an on-chain commitment to exactly the set that was judged.
5. **Finalize** — `finalizeWinner(bountyId, winnerIndex)`: the owner ratifies the winner (human-in-the-loop; the AI only recommends) and the reward is paid.

### Why this fixes the flaw
The original `submitAnswer` stored the answer as plaintext, so anyone could read pending answers and copy them. Now nothing readable exists on-chain until the submission window has closed — copying is impossible because there is nothing to copy.

## Deliverables — where each lives

| Deliverable | File |
|-------------|------|
| Updated Solidity contract (commit-reveal) | `hardhat/contracts/AIJudge.sol` |
| Advanced-track contract (encrypted, TEE) | `hardhat/contracts/AIJudgeTEE.sol` |
| README (this file) | `README.md` |
| Architecture note + advanced design + diagram | `ADVANCED.md` |
| Submission map, comparison, reflection answer | `SUBMISSION.md` |
| Tests — commit-reveal reveal cases (27) | `hardhat/test/AIJudge.t.sol` |
| Tests — advanced TEE cases (15) | `hardhat/test/AIJudgeTEE.t.sol` |

## Run the tests

```bash
cd hardhat
pnpm install                # installs forge-std (declared in package.json) into node_modules
forge test                  # 42 passing: 27 commit-reveal + 15 TEE
# Hardhat 3 also runs the same Solidity tests:
npx hardhat test solidity
```

The tests mock the Ritual LLM precompile (`0x0802`) locally so the commit-reveal and access-control logic is exercised deterministically; the *contracts* are unchanged from what deploys on Ritual.

## Frontend

The `web/` Next.js app reads bounties via `getBounty`/`getSubmission`. Note the contract API changed for commit-reveal (two deadlines; `submitCommitment`/`revealAnswer` instead of `submitAnswer`; `getSubmission` now returns `commitment`+`revealed`+`answer`). The matching frontend updates are described in `SUBMISSION.md`.

## ⚠️ Time units on Ritual
On Ritual, `block.timestamp` is expressed in **milliseconds**, so deadlines passed to `createBounty` (and the frontend) must be millisecond timestamps. The contracts only compare against `block.timestamp`, so they work on any chain as long as the client uses the same unit.

See **`ADVANCED.md`** for the Ritual-native private-judging design and **`SUBMISSION.md`** for the architecture comparison and the reflection answer.
