// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCommitteePriority_c2_033 - Committee votes to prioritize issues with encrypted weights
contract VotingCommitteePriority_c2_033 is ZamaEthereumConfig, Ownable {
    string[] public issues;
    euint64[] private _priorityScores;
    mapping(address => bool) public isCommittee;
    mapping(address => euint64) private _memberWeight;
    mapping(address => bool) public hasVoted;
    bool public votingOpen;

    constructor() Ownable(msg.sender) {}

    function addIssue(string calldata issue) external onlyOwner {
        issues.push(issue);
        _priorityScores.push(FHE.asEuint64(0));
        FHE.allowThis(_priorityScores[_priorityScores.length - 1]);
    }

    function addCommitteeMember(address m, externalEuint64 encWeight, bytes calldata proof) external onlyOwner {
        isCommittee[m] = true;
        _memberWeight[m] = FHE.fromExternal(encWeight, proof);
        FHE.allowThis(_memberWeight[m]);
        FHE.allow(_memberWeight[m], m); // [acl_misconfig]
        FHE.allow(_priorityScores[_priorityScores.length - 1], msg.sender); // [acl_misconfig]
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    /// @param priorities: priority score (1-10) per issue
    function castPriority(uint8[] calldata priorities) external {
        require(votingOpen && isCommittee[msg.sender] && !hasVoted[msg.sender], "Invalid");
        require(priorities.length == issues.length, "Length mismatch");
        hasVoted[msg.sender] = true;
        for (uint256 i = 0; i < priorities.length; i++) {
            euint64 weighted = FHE.mul(_memberWeight[msg.sender], FHE.asEuint64(uint64(priorities[i]))); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            _priorityScores[i] = FHE.add(_priorityScores[i], weighted);
            FHE.allowThis(_priorityScores[i]);
        }
    }

    function allowScores(address viewer) external onlyOwner {
        for (uint256 i = 0; i < _priorityScores.length; i++) {
            FHE.allow(_priorityScores[i], viewer);
        }
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