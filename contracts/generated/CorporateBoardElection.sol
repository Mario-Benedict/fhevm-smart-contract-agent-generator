// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CorporateBoardElection - Private weighted shareholder voting for board seats
contract CorporateBoardElection is ZamaEthereumConfig, Ownable {
    struct Candidate {
        string name;
        euint64 votes;
        bool active;
    }

    struct Election {
        string title;
        uint256 endTime;
        bool finalized;
        uint8 seats;
        uint8 candidateCount;
    }

    mapping(uint256 => Election) public elections;
    mapping(uint256 => mapping(uint8 => Candidate)) public candidates;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => euint64) public shareholderWeight;
    uint256 public electionCount;

    event ElectionCreated(uint256 indexed electionId);
    event VoteCast(uint256 indexed electionId, address indexed shareholder);
    event ElectionFinalized(uint256 indexed electionId);

    constructor() Ownable(msg.sender) {}

    function assignShares(address shareholder, externalEuint64 calldata encShares, bytes calldata inputProof)
        external
        onlyOwner
    {
        shareholderWeight[shareholder] = FHE.fromExternal(encShares, inputProof);
        FHE.allowThis(shareholderWeight[shareholder]);
        FHE.allow(shareholderWeight[shareholder], shareholder);
    }

    function createElection(string calldata title, uint256 duration, uint8 seats)
        external
        onlyOwner
        returns (uint256 electionId)
    {
        electionId = electionCount++;
        elections[electionId] = Election(title, block.timestamp + duration, false, seats, 0);
        emit ElectionCreated(electionId);
    }

    function addCandidate(uint256 electionId, string calldata candidateName) external onlyOwner {
        Election storage e = elections[electionId];
        uint8 idx = e.candidateCount++;
        candidates[electionId][idx] = Candidate({
            name: candidateName,
            votes: FHE.asEuint64(0),
            active: true
        });
        FHE.allowThis(candidates[electionId][idx].votes);
    }

    function vote(uint256 electionId, uint8 candidateIdx) external {
        require(!hasVoted[electionId][msg.sender], "Already voted");
        Election storage e = elections[electionId];
        require(block.timestamp <= e.endTime, "Election ended");
        Candidate storage c = candidates[electionId][candidateIdx];
        require(c.active, "Invalid candidate");

        c.votes = FHE.add(c.votes, shareholderWeight[msg.sender]);
        FHE.allowThis(c.votes);
        hasVoted[electionId][msg.sender] = true;
        emit VoteCast(electionId, msg.sender);
    }

    function finalizeElection(uint256 electionId) external onlyOwner {
        Election storage e = elections[electionId];
        require(block.timestamp > e.endTime, "Still active");
        require(!e.finalized, "Already finalized");
        e.finalized = true;
        for (uint8 i = 0; i < e.candidateCount; i++) {
            FHE.allow(candidates[electionId][i].votes, owner());
        }
        emit ElectionFinalized(electionId);
    }
}
