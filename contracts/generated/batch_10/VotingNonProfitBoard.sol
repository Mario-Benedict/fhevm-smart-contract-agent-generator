// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingNonProfitBoard
/// @notice Nonprofit board election where conflict-of-interest flags are encrypted.
///         Board members vote on candidates; members with encrypted conflicts auto-abstain.
contract VotingNonProfitBoard is ZamaEthereumConfig, Ownable {
    struct BoardMember {
        ebool conflictFlag;  // encrypted: 1 if has conflict with a candidate
        bool isRegistered;
        bool hasVoted;
    }

    struct Candidate {
        string name;
        euint16 votes;
        bool active;
    }

    mapping(address => BoardMember) private members;
    mapping(uint256 => Candidate) public candidates;
    uint256 public candidateCount;
    address[] public memberList;
    bool public electionOpen;

    event MemberRegistered(address indexed m);
    event VoteCast(address indexed m, uint256 candidateId);
    event ElectionOpened();
    event ElectionClosed();

    constructor() Ownable(msg.sender) {}

    function addCandidate(string calldata name) external onlyOwner {
        candidates[candidateCount] = Candidate({ name: name, votes: FHE.asEuint16(0), active: true });
        FHE.allowThis(candidates[candidateCount].votes);
        candidateCount++;
    }

    function registerMember(address m, externalEbool encConflict, bytes calldata proof) external onlyOwner {
        members[m].conflictFlag = FHE.fromExternal(encConflict, proof);
        members[m].isRegistered = true;
        members[m].hasVoted = false;
        FHE.allowThis(members[m].conflictFlag);
        memberList.push(m);
        emit MemberRegistered(m);
    }

    function openElection() external onlyOwner { electionOpen = true; emit ElectionOpened(); }

    function vote(uint256 candidateId) external {
        require(electionOpen, "Not open");
        BoardMember storage bm = members[msg.sender];
        require(bm.isRegistered, "Not registered");
        require(!bm.hasVoted, "Already voted");
        require(candidateId < candidateCount && candidates[candidateId].active, "Invalid candidate");

        bm.hasVoted = true;
        // Only count vote if no conflict: select(NOT conflictFlag, 1, 0)
        ebool noConflict = FHE.not(bm.conflictFlag);
        euint16 voteWeight = FHE.select(noConflict, FHE.asEuint16(1), FHE.asEuint16(0));
        candidates[candidateId].votes = FHE.add(candidates[candidateId].votes, voteWeight);
        FHE.allowThis(candidates[candidateId].votes);
        emit VoteCast(msg.sender, candidateId);
    }

    function closeElection() external onlyOwner {
        electionOpen = false;
        emit ElectionClosed();
    }

    function allowCandidateVotes(uint256 candidateId, address viewer) external onlyOwner {
        FHE.allow(candidates[candidateId].votes, viewer);
    }
}
