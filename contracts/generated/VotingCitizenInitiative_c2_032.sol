// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCitizenInitiative_c2_032 - Petition-to-vote: collect encrypted signatures, then vote
contract VotingCitizenInitiative_c2_032 is ZamaEthereumConfig, Ownable {
    struct Initiative {
        string title;
        euint32 sigCount;
        euint64 votesFor;
        euint64 votesAgainst;
        bool onBallot;
        uint256 signatureDeadline;
    }

    euint32 private _requiredSigs;
    Initiative[] public initiatives;
    mapping(address => mapping(uint256 => bool)) public hasSigned;
    mapping(address => mapping(uint256 => bool)) public hasVotedOn;
    mapping(address => bool) public isCitizen;
    mapping(address => euint64) private _citizenWeight;

    constructor(externalEuint32 encRequired, bytes memory proof) Ownable(msg.sender) {
        _requiredSigs = FHE.fromExternal(encRequired, proof);
        FHE.allowThis(_requiredSigs);
    }

    function registerCitizen(address c, externalEuint64 encWeight, bytes calldata proof) external onlyOwner {
        isCitizen[c] = true;
        _citizenWeight[c] = FHE.fromExternal(encWeight, proof);
        FHE.allowThis(_citizenWeight[c]);
        FHE.allow(_citizenWeight[c], c);
    }

    function propose(string calldata title, uint256 durationDays) external returns (uint256 id) {
        require(isCitizen[msg.sender], "Not citizen");
        id = initiatives.length;
        initiatives.push(Initiative({
            title: title, sigCount: FHE.asEuint32(0), votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0), onBallot: false,
            signatureDeadline: block.timestamp + durationDays * 1 days
        }));
        FHE.allowThis(initiatives[id].sigCount);
        FHE.allowThis(initiatives[id].votesFor);
        FHE.allowThis(initiatives[id].votesAgainst);
    }

    function sign(uint256 initiativeId) external {
        require(isCitizen[msg.sender] && !hasSigned[msg.sender][initiativeId], "Invalid");
        require(block.timestamp < initiatives[initiativeId].signatureDeadline, "Expired");
        hasSigned[msg.sender][initiativeId] = true;
        initiatives[initiativeId].sigCount = FHE.add(initiatives[initiativeId].sigCount, FHE.asEuint32(1));
        FHE.allowThis(initiatives[initiativeId].sigCount);
    }

    function putOnBallot(uint256 initiativeId) external onlyOwner {
        initiatives[initiativeId].onBallot = true;
    }

    function vote(uint256 initiativeId, bool support) external {
        require(initiatives[initiativeId].onBallot && isCitizen[msg.sender], "Invalid");
        require(!hasVotedOn[msg.sender][initiativeId], "Already voted");
        hasVotedOn[msg.sender][initiativeId] = true;
        if (support) {
            initiatives[initiativeId].votesFor = FHE.add(initiatives[initiativeId].votesFor, _citizenWeight[msg.sender]);
            FHE.allowThis(initiatives[initiativeId].votesFor);
        } else {
            initiatives[initiativeId].votesAgainst = FHE.add(initiatives[initiativeId].votesAgainst, _citizenWeight[msg.sender]);
            FHE.allowThis(initiatives[initiativeId].votesAgainst);
        }
    }

    function allowInitiativeData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(initiatives[id].sigCount, viewer);
        FHE.allow(initiatives[id].votesFor, viewer);
        FHE.allow(initiatives[id].votesAgainst, viewer);
    }
}
