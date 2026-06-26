"use client";

import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import {
  canCommit,
  canReveal,
  computeCommitment,
  randomSalt,
  saveCommitLocal,
  loadCommitLocal,
  type Bounty,
} from "@/lib/bounty";
import { useWriteTx } from "@/hooks/useWriteTx";
import { Card, CardHeader, CardBody, Field, Input, Textarea, Button, TxStatus, Notice } from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

export function CommitReveal({
  bountyId,
  bounty,
  onChanged,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onChanged: () => void;
}) {
  const { address, isConnected } = useAccount();
  const now = useNow();
  const commitPhase = canCommit(bounty, now);
  const revealPhase = canReveal(bounty, now);

  const [answer, setAnswer] = useState("");
  const [salt, setSalt] = useState<`0x${string}` | "">("");
  const tx = useWriteTx(() => onChanged());

  // In the reveal phase, pre-fill answer + salt from the local commit record.
  useEffect(() => {
    if (revealPhase && contractAddress && address) {
      const saved = loadCommitLocal(contractAddress, bountyId, address);
      if (saved) {
        setAnswer((a) => (a ? a : saved.answer));
        setSalt((s) => (s ? s : saved.salt));
      }
    }
  }, [revealPhase, bountyId, address]);

  if (!commitPhase && !revealPhase) return null;

  async function handleCommit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress || !address) return;
    const newSalt = randomSalt();
    const commitment = computeCommitment(answer.trim(), newSalt, address, bountyId);
    // persist BEFORE sending so the salt is never lost
    saveCommitLocal(contractAddress, bountyId, address, { answer: answer.trim(), salt: newSalt });
    setSalt(newSalt);
    try {
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitCommitment",
        args: [bountyId, commitment],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  async function handleReveal(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !salt || !contractAddress) return;
    try {
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "revealAnswer",
        args: [bountyId, answer.trim(), salt],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  if (commitPhase) {
    return (
      <Card>
        <CardHeader
          title="Commit your answer"
          subtitle="Only a hash goes on-chain now. Your answer stays private until the reveal phase."
        />
        <CardBody>
          <form onSubmit={handleCommit} className="space-y-3">
            <Field label="Your answer" hint="Kept locally; you'll reveal it after the submission deadline.">
              <Textarea value={answer} onChange={(e) => setAnswer(e.target.value)} rows={5} placeholder="Write your submission…" />
            </Field>
            <Notice tone="indigo">
              A random salt is generated and stored in your browser so you can reveal later. Keep this device/browser.
            </Notice>
            <Button type="submit" disabled={!isConnected || !answer.trim() || tx.isBusy} className="w-full">
              {tx.isBusy ? "Committing…" : "Commit (hash only)"}
            </Button>
            {!isConnected && <p className="text-xs text-zinc-500">Connect your wallet to commit.</p>}
            <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
          </form>
        </CardBody>
      </Card>
    );
  }

  // reveal phase
  return (
    <Card>
      <CardHeader
        title="Reveal your answer"
        subtitle="Submission closed. Reveal your answer + salt; the contract verifies it matches your commitment."
      />
      <CardBody>
        <form onSubmit={handleReveal} className="space-y-3">
          <Field label="Your answer">
            <Textarea value={answer} onChange={(e) => setAnswer(e.target.value)} rows={5} placeholder="The exact answer you committed…" />
          </Field>
          <Field label="Salt" hint="Auto-filled from this browser. Paste it if you committed elsewhere.">
            <Input value={salt} onChange={(e) => setSalt(e.target.value as `0x${string}`)} placeholder="0x…" />
          </Field>
          <Button type="submit" disabled={!isConnected || !answer.trim() || !salt || tx.isBusy} className="w-full">
            {tx.isBusy ? "Revealing…" : "Reveal answer"}
          </Button>
          {!isConnected && <p className="text-xs text-zinc-500">Connect your wallet to reveal.</p>}
          <TxStatus state={tx.state} error={tx.error} hash={tx.hash} explorerBase={explorerBase} />
        </form>
      </CardBody>
    </Card>
  );
}
