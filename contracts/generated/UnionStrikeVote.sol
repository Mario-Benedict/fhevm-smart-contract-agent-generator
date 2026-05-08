// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title UnionStrikeVote - Confidential strike authorization ballot for union members
contract UnionStrikeVote is ZamaEthereumConfig, Ownable {
    struct Ballot {
        string issue;
        euint32 yesVotes;
        euint32 noVotes;
        euint32 abstainVotes;
        uint256 endTime;
        bool finalized;
        uint32 totalMembers;
    }

    mapping(uint256 => Ballot) public ballots;
    mapping(uint256 => mapping(address => bool)) public voted;
    mapping(address => bool) public members;
    uint256 public ballotCount;
    uint32 public memberCount;

    event BallotCreated(uint256 indexed ballotId, string issue);
    event VoteCast(uint256 indexed ballotId);
    event BallotFinalized(uint256 indexed ballotId);

    constructor() Ownable(msg.sender) {}

    function enrollMember(address member) external onlyOwner {
        if (!members[member]) {
            members[member] = true;
            memberCount++;
        }
    }

    function createBallot(string calldata issue, uint256 duration) external onlyOwner returns (uint256 ballotId) {
        ballotId = ballotCount++;
        Ballot storage b = ballots[ballotId];
        b.issue = issue;
        b.endTime = block.timestamp + duration;
        b.yesVotes = FHE.asEuint32(0);
        b.noVotes = FHE.asEuint32(0);
        b.abstainVotes = FHE.asEuint32(0);
        b.totalMembers = memberCount;
        FHE.allowThis(b.yesVotes);
        FHE.allowThis(b.noVotes);
        FHE.allowThis(b.abstainVotes);
        emit BallotCreated(ballotId, issue);
    }

    // choice: 0=yes, 1=no, 2=abstain
    function castVote(uint256 ballotId, externalEuint32 calldata encChoice, bytes calldata inputProof) external {
        require(members[msg.sender], "Not a member");
        require(!voted[ballotId][msg.sender], "Already voted");
        Ballot storage b = ballots[ballotId];
        require(block.timestamp <= b.endTime, "Ballot closed");

        euint32 choice = FHE.fromExternal(encChoice, inputProof);
        ebool isYes = FHE.eq(choice, FHE.asEuint32(0));
        ebool isNo = FHE.eq(choice, FHE.asEuint32(1));
        ebool isAbstain = FHE.eq(choice, FHE.asEuint32(2));

        b.yesVotes = FHE.add(b.yesVotes, FHE.select(isYes, FHE.asEuint32(1), FHE.asEuint32(0)));
        b.noVotes = FHE.add(b.noVotes, FHE.select(isNo, FHE.asEuint32(1), FHE.asEuint32(0)));
        b.abstainVotes = FHE.add(b.abstainVotes, FHE.select(isAbstain, FHE.asEuint32(1), FHE.asEuint32(0)));

        FHE.allowThis(b.yesVotes);
        FHE.allowThis(b.noVotes);
        FHE.allowThis(b.abstainVotes);
        voted[ballotId][msg.sender] = true;
        emit VoteCast(ballotId);
    }

    function finalizeBallot(uint256 ballotId) external onlyOwner {
        Ballot storage b = ballots[ballotId];
        require(block.timestamp > b.endTime, "Still active");
        require(!b.finalized, "Done");
        b.finalized = true;
        FHE.allow(b.yesVotes, owner());
        FHE.allow(b.noVotes, owner());
        FHE.allow(b.abstainVotes, owner());
        emit BallotFinalized(ballotId);
    }
}
