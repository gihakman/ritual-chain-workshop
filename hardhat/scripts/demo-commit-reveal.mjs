// Live commit -> reveal demo against the deployed AIJudge on Ritual (chain 1979).
//
//   AIJudge:    0x3e1aC2CCb7F4A63cC88E396a6b1719D865dc2F7c
//   AIJudgeTEE: 0xBF337DEf0fb03B030Db196F480f9A90EC2ef9B68
//
// Proves the privacy property end-to-end: after submitCommitment the answer is
// NOT readable on-chain; after revealAnswer it is. Run:
//   DEPLOYER_PRIVATE_KEY=0x... node hardhat/scripts/demo-commit-reveal.mjs
//
// NOTE: Ritual block.timestamp is in MILLISECONDS, so deadlines are ms here.
import { createPublicClient, createWalletClient, http, defineChain, parseEther, keccak256, encodePacked } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = "https://rpc.ritualfoundation.org";
const chain = defineChain({ id: 1979, name: "Ritual", nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const AIJUDGE = "0x3e1aC2CCb7F4A63cC88E396a6b1719D865dc2F7c";

const abi = [
  { type: "function", name: "nextBountyId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "createBounty", stateMutability: "payable", inputs: [{ name: "title", type: "string" }, { name: "rubric", type: "string" }, { name: "submissionDeadline", type: "uint256" }, { name: "revealDeadline", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "submitCommitment", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "bytes32" }], outputs: [] },
  { type: "function", name: "revealAnswer", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "string" }, { type: "bytes32" }], outputs: [] },
  { type: "function", name: "getSubmission", stateMutability: "view", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [{ name: "submitter", type: "address" }, { name: "commitment", type: "bytes32" }, { name: "revealed", type: "bool" }, { name: "answer", type: "string" }] },
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const pub = createPublicClient({ chain, transport: http(RPC) });
  const acct = privateKeyToAccount(process.env.DEPLOYER_PRIVATE_KEY);
  const w = createWalletClient({ account: acct, chain, transport: http(RPC) });
  const tx = { gas: 800000n, maxFeePerGas: 5_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n };

  const id = await pub.readContract({ address: AIJUDGE, abi, functionName: "nextBountyId" });
  const ts = (await pub.getBlock()).timestamp;            // milliseconds on Ritual
  const sub = ts + 25_000n, rev = ts + 120_000n;

  const answer = "Commit-reveal keeps my answer private until judging.";
  const salt = keccak256(encodePacked(["string"], ["demo-salt"]));
  const commitment = keccak256(encodePacked(["string", "bytes32", "address", "uint256"], [answer, salt, acct.address, id]));

  let h = await w.writeContract({ address: AIJUDGE, abi, functionName: "createBounty", args: ["Live commit-reveal demo", "Best private answer wins", sub, rev], value: parseEther("0.001"), ...tx });
  await pub.waitForTransactionReceipt({ hash: h }); console.log("createBounty:", h);

  h = await w.writeContract({ address: AIJUDGE, abi, functionName: "submitCommitment", args: [id, commitment], ...tx });
  await pub.waitForTransactionReceipt({ hash: h }); console.log("submitCommitment:", h);

  let s = await pub.readContract({ address: AIJUDGE, abi, functionName: "getSubmission", args: [id, 0n] });
  console.log("after commit -> revealed:", s[2], "answer:", JSON.stringify(s[3]), "(hidden)");

  while ((await pub.getBlock()).timestamp <= sub) await sleep(3000);

  h = await w.writeContract({ address: AIJUDGE, abi, functionName: "revealAnswer", args: [id, answer, salt], ...tx });
  await pub.waitForTransactionReceipt({ hash: h }); console.log("revealAnswer:", h);

  s = await pub.readContract({ address: AIJUDGE, abi, functionName: "getSubmission", args: [id, 0n] });
  console.log("after reveal -> revealed:", s[2], "answer:", JSON.stringify(s[3]));
  console.log(s[2] && s[3] === answer ? "OK: commit-reveal verified on-chain" : "MISMATCH");
}
main().catch((e) => { console.error(e); process.exit(1); });
