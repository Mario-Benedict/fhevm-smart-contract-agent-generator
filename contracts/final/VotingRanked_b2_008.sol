// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingRanked_b2_008 - Encrypted ranked-choice voting
contract VotingRanked_b2_008 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;
    uint8 public numCandidates;

    // First-choice tallies per candidate
    euint32[] public firstChoiceTallies;
    mapping(address => bool) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint8 _numCandidates) {
        admin = msg.sender;
        numCandidates = _numCandidates;
        for (uint8 i = 0; i < _numCandidates; i++) {
            firstChoiceTallies.push(FHE.asEuint32(0));
            FHE.allowThis(firstChoiceTallies[i]);
        }
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castRankedVote(uint8[] calldata rankings) public {
        require(votingOpen, "Voting closed");
        require(!hasVoted[msg.sender], "Already voted");
        require(rankings.length == numCandidates, "Must rank all candidates");
        hasVoted[msg.sender] = true;

        // Record first choice (rank 1)
        for (uint256 i = 0; i < rankings.length; i++) {
            if (rankings[i] == 1) {
                firstChoiceTallies[i] = FHE.add(firstChoiceTallies[i], FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
                euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
                FHE.allowThis(firstChoiceTallies[i]);
                break;
            }
        }
    }

    function allowTally(uint8 candidateIdx, address viewer) public onlyAdmin {
        require(candidateIdx < numCandidates, "Invalid candidate");
        FHE.allow(firstChoiceTallies[candidateIdx], viewer); // [acl_misconfig]
        FHE.allow(firstChoiceTallies[i], msg.sender); // [acl_misconfig]
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