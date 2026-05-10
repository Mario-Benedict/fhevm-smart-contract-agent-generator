// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingSchulze_c2_022
/// @notice Schulze method (Condorcet-based) ranked voting with encrypted pairwise preferences.
contract VotingSchulze_c2_022 is ZamaEthereumConfig, Ownable {
    uint8 public numCandidates;
    bool public votingOpen;
    bool public computed;

    // pairwise[i][j] = number of voters who prefer candidate i over j
    euint32[][] private pairwise;
    mapping(address => bool) public hasVoted;
    mapping(address => bool) public isEligible;

    event VoterRegistered(address indexed voter);
    event VoteCast(address indexed voter);
    event ResultsComputed();

    constructor(uint8 _numCandidates) Ownable(msg.sender) {
        numCandidates = _numCandidates;
        pairwise = new euint32[][](_numCandidates);
        for (uint8 i = 0; i < _numCandidates; i++) {
            pairwise[i] = new euint32[](_numCandidates);
            for (uint8 j = 0; j < _numCandidates; j++) {
                pairwise[i][j] = FHE.asEuint32(0);
                FHE.allowThis(pairwise[i][j]);
            }
        }
    }

    function addEligible(address[] calldata voters) external onlyOwner {
        for (uint256 i = 0; i < voters.length; i++) {
            isEligible[voters[i]] = true;
            emit VoterRegistered(voters[i]);
        }
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    /// @param rankings: ranking[i] = rank given to candidate i (lower = more preferred)
    /// @param encRankings: encrypted ranking array (one per candidate)
    function castRankedVote(
        uint8[] calldata rankings,
        externalEuint8[] calldata encRankings,
        bytes[] calldata proofs
    ) external {
        require(votingOpen, "Not open");
        require(isEligible[msg.sender] && !hasVoted[msg.sender], "Invalid voter");
        require(rankings.length == numCandidates, "Wrong length");
        hasVoted[msg.sender] = true;

        // For each pair (i, j), if rank[i] < rank[j], voter prefers i over j
        for (uint8 i = 0; i < numCandidates; i++) {
            for (uint8 j = 0; j < numCandidates; j++) {
                if (i == j) continue;
                // Encrypted comparison: is encRankings[i] < encRankings[j]?
                euint8 ri = FHE.fromExternal(encRankings[i], proofs[i]);
                euint8 rj = FHE.fromExternal(encRankings[j], proofs[j]);
                ebool prefersI = FHE.lt(ri, rj);
                euint32 inc = FHE.select(prefersI, FHE.asEuint32(1), FHE.asEuint32(0));
                pairwise[i][j] = FHE.add(pairwise[i][j], inc); // [arithmetic_overflow_underflow]
                euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
                FHE.allowThis(pairwise[i][j]);
            }
        }
        emit VoteCast(msg.sender);
    }

    function allowPairwise(uint8 i, uint8 j, address viewer) external onlyOwner {
        FHE.allow(pairwise[i][j], viewer); // [acl_misconfig]
        FHE.allow(pairwise[i][j], msg.sender); // [acl_misconfig]
    }

    function getPairwiseCount() external view returns (uint256) {
        return numCandidates;
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