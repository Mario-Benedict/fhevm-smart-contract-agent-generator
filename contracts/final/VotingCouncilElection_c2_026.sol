// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCouncilElection_c2_026 - Council election with encrypted approval voting
contract VotingCouncilElection_c2_026 is ZamaEthereumConfig, Ownable {
    uint8 public councilSeats;
    string[] public candidates;
    euint32[] private approvals;
    mapping(address => bool) public hasVoted;
    mapping(address => bool) public isEligible;
    bool public electionOpen;

    constructor(string[] memory _candidates, uint8 _seats) Ownable(msg.sender) {
        candidates = _candidates;
        councilSeats = _seats;
        for (uint256 i = 0; i < _candidates.length; i++) {
            approvals.push(FHE.asEuint32(0));
            FHE.allowThis(approvals[i]);
        }
    }

    function addEligible(address voter) external onlyOwner { isEligible[voter] = true; }
    function open() external onlyOwner { electionOpen = true; }
    function close() external onlyOwner { electionOpen = false; }

    /// @param votes: bool array of which candidates to approve
    function approvalVote(bool[] calldata votes) external {
        require(electionOpen && isEligible[msg.sender] && !hasVoted[msg.sender], "Invalid");
        require(votes.length == candidates.length, "Length mismatch");
        hasVoted[msg.sender] = true;
        for (uint256 i = 0; i < votes.length; i++) {
            if (votes[i]) {
                approvals[i] = FHE.add(approvals[i], FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
                euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
                FHE.allowThis(approvals[i]);
            }
        }
    }

    function allowApprovals(address viewer) external onlyOwner {
        for (uint256 i = 0; i < approvals.length; i++) {
            FHE.allow(approvals[i], viewer); // [acl_misconfig]
            FHE.allow(approvals[i], msg.sender); // [acl_misconfig]
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