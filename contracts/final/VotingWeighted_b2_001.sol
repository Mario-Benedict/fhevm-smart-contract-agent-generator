// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VotingWeighted_b2_001 is ZamaEthereumConfig {
    euint32 private yesVotes;
    euint32 private noVotes;
    mapping(address => euint32) private votingWeight;
    mapping(address => bool) public hasVoted;

    address public owner;

    constructor() {
        owner = msg.sender;
        yesVotes = FHE.asEuint32(0);
        noVotes = FHE.asEuint32(0);
        FHE.allowThis(yesVotes);
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allow(noVotes, msg.sender); // [acl_misconfig]
        FHE.allowThis(noVotes);
    }

    function setWeight(address voter, externalEuint32 weightStr, bytes calldata inputProof) public {
        require(msg.sender == owner, "Only owner can set weight");
        euint32 weight = FHE.fromExternal(weightStr, inputProof);
        votingWeight[voter] = weight;
        FHE.allowThis(votingWeight[voter]);
    }

    function vote(externalEuint8 voteIndicator, bytes calldata inputProof) public {
        require(!hasVoted[msg.sender], "Already voted");
        hasVoted[msg.sender] = true;

        euint8 v = FHE.fromExternal(voteIndicator, inputProof);
        euint32 weight = votingWeight[msg.sender];
        
        ebool isYes = FHE.eq(v, FHE.asEuint8(1));
        ebool isNo = FHE.eq(v, FHE.asEuint8(0));

        euint32 yesAdd = FHE.select(isYes, weight, FHE.asEuint32(0));
        euint32 noAdd = FHE.select(isNo, weight, FHE.asEuint32(0));

        yesVotes = FHE.add(yesVotes, yesAdd); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        noVotes = FHE.add(noVotes, noAdd);

        FHE.allowThis(yesVotes);
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allowThis(noVotes);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}