// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingNominationPool_c2_030 - Nomination and election with encrypted vote shares
contract VotingNominationPool_c2_030 is ZamaEthereumConfig, Ownable {
    struct Nominee {
        address addr;
        string bio;
        euint32 nominations;
        euint64 finalVotes;
        bool qualified;
    }

    Nominee[] public nominees;
    mapping(address => bool) public isNominator;
    mapping(address => bool) public hasNominated;
    mapping(address => bool) public hasVoted;
    mapping(address => euint64) private _votingPower;
    bool public nominationOpen;
    bool public electionOpen;
    uint32 public qualificationThreshold;

    constructor(uint32 _threshold) Ownable(msg.sender) {
        qualificationThreshold = _threshold;
    }

    function addNominator(address n) external onlyOwner { isNominator[n] = true; }

    function nominate(address candidate, string calldata bio) external {
        require(nominationOpen && isNominator[msg.sender] && !hasNominated[msg.sender], "Invalid");
        hasNominated[msg.sender] = true;
        uint256 id = nominees.length;
        nominees.push(Nominee({ addr: candidate, bio: bio, nominations: FHE.asEuint32(1), finalVotes: FHE.asEuint64(0), qualified: false }));
        FHE.allowThis(nominees[id].nominations);
        FHE.allowThis(nominees[id].finalVotes);
    }

    function addNomination(uint256 nomineeId) external {
        require(nominationOpen && isNominator[msg.sender] && !hasNominated[msg.sender], "Invalid");
        hasNominated[msg.sender] = true;
        nominees[nomineeId].nominations = FHE.add(nominees[nomineeId].nominations, FHE.asEuint32(1));
        FHE.allowThis(nominees[nomineeId].nominations);
    }

    function qualifyNominee(uint256 nomineeId) external onlyOwner {
        nominees[nomineeId].qualified = true;
    }

    function grantVotingPower(address voter, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        _votingPower[voter] = FHE.fromExternal(encPower, proof);
        FHE.allowThis(_votingPower[voter]);
        FHE.allow(_votingPower[voter], voter);
    }

    function vote(uint256 nomineeId) external {
        require(electionOpen && nominees[nomineeId].qualified && !hasVoted[msg.sender], "Invalid");
        hasVoted[msg.sender] = true;
        nominees[nomineeId].finalVotes = FHE.add(nominees[nomineeId].finalVotes, _votingPower[msg.sender]);
        FHE.allowThis(nominees[nomineeId].finalVotes);
    }

    function openNomination() external onlyOwner { nominationOpen = true; }
    function closeNomination() external onlyOwner { nominationOpen = false; }
    function openElection() external onlyOwner { electionOpen = true; }
    function closeElection() external onlyOwner { electionOpen = false; }

    function allowNomineeVotes(uint256 nomineeId, address viewer) external onlyOwner {
        FHE.allow(nominees[nomineeId].nominations, viewer);
        FHE.allow(nominees[nomineeId].finalVotes, viewer);
    }
}
