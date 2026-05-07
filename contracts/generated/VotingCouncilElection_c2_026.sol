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
                approvals[i] = FHE.add(approvals[i], FHE.asEuint32(1));
                FHE.allowThis(approvals[i]);
            }
        }
    }

    function allowApprovals(address viewer) external onlyOwner {
        for (uint256 i = 0; i < approvals.length; i++) {
            FHE.allow(approvals[i], viewer);
        }
    }
}
