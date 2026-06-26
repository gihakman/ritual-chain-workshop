// AUTO-GENERATED from contracts/AIJudge.sol (commit-reveal). Do not edit by hand.
const abi = [
  {
    "type": "function",
    "name": "MAX_ANSWER_LENGTH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_SUBMISSIONS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "commitmentIndexOf",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "participant",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "exists",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "index",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "createBounty",
    "inputs": [
      {
        "name": "title",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "rubric",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "submissionDeadline",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "revealDeadline",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "finalizeWinner",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "winnerIndex",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getBounty",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct AIJudge.BountyView",
        "components": [
          {
            "name": "owner",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "title",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "rubric",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "reward",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "submissionDeadline",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "revealDeadline",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "judged",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "finalized",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "submissionCount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "revealedCount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "winnerIndex",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "revealedAnswersHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "aiReview",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getSubmission",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "index",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "submitter",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "commitment",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "revealed",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "answer",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "judgeAll",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "llmInput",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "nextBountyId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "revealAnswer",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "answer",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "salt",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "submitCommitment",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "commitment",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AllAnswersJudged",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "revealedAnswersHash",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "revealedCount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "aiReview",
        "type": "bytes",
        "indexed": false,
        "internalType": "bytes"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "AnswerRevealed",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "submissionIndex",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "submitter",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BountyCreated",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "title",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      },
      {
        "name": "reward",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "submissionDeadline",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "revealDeadline",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CommitmentSubmitted",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "submissionIndex",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "submitter",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "commitment",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "WinnerFinalized",
    "inputs": [
      {
        "name": "bountyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "winnerIndex",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "winner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "reward",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyCommitted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AlreadyFinalized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AlreadyJudged",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AlreadyRevealed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AnswerTooLong",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadDeadlines",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BountyNotFound",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidReveal",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidWinnerIndex",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NoCommitment",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NoRevealedAnswers",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotBountyOwner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotInRevealWindow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotJudged",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PaymentFailed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RevealNotOver",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RewardRequired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SubmissionsClosed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "TooManySubmissions",
    "inputs": []
  },
  {
    "type": "error",
    "name": "WinnerNotRevealed",
    "inputs": []
  }
] as const;

export default abi;
