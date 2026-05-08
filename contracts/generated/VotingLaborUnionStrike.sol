// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingLaborUnionStrike
/// @notice Labor union strike ballot with anonymous member voting. Quorum is encrypted.
///         Strike authorized only when encrypted yes-vote count exceeds encrypted quorum.
contract VotingLaborUnionStrike is ZamaEthereumConfig, Ownable {
    struct Ballot {
        euint32 yesVotes;
        euint32 noVotes;
        euint32 quorumRequired;
        uint256 deadline;
        bool open;
        bool authorized;
        string resolution;
    }

    mapping(uint256 => Ballot) private ballots;
    uint256 public ballotCount;
    mapping(address => bool) public isMember;
    mapping(uint256 => mapping(address => bool)) private hasVoted;
    uint256 public memberCount;

    event BallotCreated(uint256 indexed id, string resolution);
    event VoteCast(uint256 indexed id, address indexed member);
    event StrikeAuthorized(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function addMember(address m) external onlyOwner {
        if (!isMember[m]) { isMember[m] = true; memberCount++; }
    }

    function removeMember(address m) external onlyOwner {
        if (isMember[m]) { isMember[m] = false; memberCount--; }
    }

    function createBallot(
        string calldata resolution,
        externalEuint32 encQuorum, bytes calldata proof,
        uint256 durationHours
    ) external onlyOwner returns (uint256 id) {
        id = ballotCount++;
        Ballot storage b = ballots[id];
        b.resolution = resolution;
        b.quorumRequired = FHE.fromExternal(encQuorum, proof);
        b.yesVotes = FHE.asEuint32(0);
        b.noVotes = FHE.asEuint32(0);
        b.deadline = block.timestamp + durationHours * 1 hours;
        b.open = true;
        FHE.allowThis(b.quorumRequired);
        FHE.allowThis(b.yesVotes);
        FHE.allowThis(b.noVotes);
        emit BallotCreated(id, resolution);
    }

    function castVote(uint256 id, bool supportStrike) external {
        require(isMember[msg.sender], "Not member");
        Ballot storage b = ballots[id];
        require(b.open && block.timestamp <= b.deadline, "Ballot closed");
        require(!hasVoted[id][msg.sender], "Already voted");
        hasVoted[id][msg.sender] = true;
        if (supportStrike) {
            b.yesVotes = FHE.add(b.yesVotes, FHE.asEuint32(1));
            FHE.allowThis(b.yesVotes);
        } else {
            b.noVotes = FHE.add(b.noVotes, FHE.asEuint32(1));
            FHE.allowThis(b.noVotes);
        }
        emit VoteCast(id, msg.sender);
    }

    function finalizeBallot(uint256 id) external onlyOwner {
        Ballot storage b = ballots[id];
        require(b.open, "Not open");
        b.open = false;
        ebool quorumMet = FHE.ge(b.yesVotes, b.quorumRequired);
        ebool majorityYes = FHE.gt(b.yesVotes, b.noVotes);
        ebool authorized = FHE.and(quorumMet, majorityYes);
        if (FHE.isInitialized(authorized)) {
            b.authorized = true;
            emit StrikeAuthorized(id);
        }
    }

    function allowBallotResults(uint256 id, address viewer) external onlyOwner {
        FHE.allow(ballots[id].yesVotes, viewer);
        FHE.allow(ballots[id].noVotes, viewer);
    }
}
