import type { Address } from "viem";
import { keccak256, encodePacked } from "viem";

/**
 * Shape of the `getBounty` struct (BountyView) returned by the commit-reveal
 * AIJudge contract. wagmi returns a struct as a named object.
 */
export type Bounty = {
  owner: Address;
  title: string;
  rubric: string;
  reward: bigint;
  submissionDeadline: bigint;
  revealDeadline: bigint;
  judged: boolean;
  finalized: boolean;
  submissionCount: bigint;
  revealedCount: bigint;
  winnerIndex: bigint;
  revealedAnswersHash: `0x${string}`;
  aiReview: `0x${string}`;
};

/** getBounty already returns named fields; normalize to our Bounty type. */
export function parseBounty(raw: Bounty): Bounty {
  return raw;
}

export type BountyStatus = "commit" | "reveal" | "judging" | "judged" | "finalized";

/**
 * Lifecycle phase. NOTE: Ritual `block.timestamp` is in MILLISECONDS, so the
 * deadlines are ms and we compare against `Date.now()` (also ms).
 */
export function getBountyStatus(b: Bounty, nowMs: number = Date.now()): BountyStatus {
  if (b.finalized) return "finalized";
  if (b.judged) return "judged";
  if (nowMs < Number(b.submissionDeadline)) return "commit";
  if (nowMs < Number(b.revealDeadline)) return "reveal";
  return "judging";
}

export const STATUS_META: Record<
  BountyStatus,
  { label: string; tone: "green" | "amber" | "indigo" | "zinc" }
> = {
  commit: { label: "Commit phase", tone: "green" },
  reveal: { label: "Reveal phase", tone: "amber" },
  judging: { label: "Ready for judging", tone: "amber" },
  judged: { label: "Judged", tone: "indigo" },
  finalized: { label: "Finalized", tone: "zinc" },
};

/** Can a participant submit a commitment? (before the submission deadline) */
export function canCommit(b: Bounty, nowMs = Date.now()): boolean {
  return !b.judged && !b.finalized && nowMs < Number(b.submissionDeadline);
}

/** Can a participant reveal? (between the submission and reveal deadlines) */
export function canReveal(b: Bounty, nowMs = Date.now()): boolean {
  return (
    !b.judged &&
    !b.finalized &&
    nowMs >= Number(b.submissionDeadline) &&
    nowMs < Number(b.revealDeadline)
  );
}

/** commitment = keccak256(abi.encodePacked(answer, salt, sender, bountyId)). */
export function computeCommitment(
  answer: string,
  salt: `0x${string}`,
  sender: Address,
  bountyId: bigint,
): `0x${string}` {
  return keccak256(
    encodePacked(
      ["string", "bytes32", "address", "uint256"],
      [answer, salt, sender, bountyId],
    ),
  );
}

/** Random 32-byte salt for a commitment. */
export function randomSalt(): `0x${string}` {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return ("0x" +
    Array.from(b)
      .map((x) => x.toString(16).padStart(2, "0"))
      .join("")) as `0x${string}`;
}

// --- local persistence so a committer can reveal later -------------------- //

const saltKey = (contract: string, bountyId: bigint, sender: string) =>
  `aijudge:commit:${contract}:${bountyId}:${sender}`.toLowerCase();

export function saveCommitLocal(
  contract: string,
  bountyId: bigint,
  sender: string,
  data: { answer: string; salt: `0x${string}` },
): void {
  try {
    localStorage.setItem(saltKey(contract, bountyId, sender), JSON.stringify(data));
  } catch {
    /* storage unavailable — user can re-enter answer+salt manually to reveal */
  }
}

export function loadCommitLocal(
  contract: string,
  bountyId: bigint,
  sender: string,
): { answer: string; salt: `0x${string}` } | null {
  try {
    const v = localStorage.getItem(saltKey(contract, bountyId, sender));
    return v ? (JSON.parse(v) as { answer: string; salt: `0x${string}` }) : null;
  } catch {
    return null;
  }
}
