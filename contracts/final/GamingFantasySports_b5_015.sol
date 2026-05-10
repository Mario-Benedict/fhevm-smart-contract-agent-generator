// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingFantasySports_b5_015 - Encrypted fantasy sports draft and scoring
contract GamingFantasySports_b5_015 is ZamaEthereumConfig {
    address public commissioner;
    bool public draftOpen;
    bool public seasonEnded;

    struct Team {
        string name;
        euint32 totalScore;
        euint64 prizeWon;
        bool registered;
    }

    mapping(address => Team) private teams;
    address[] public teamList;
    euint64 private prizePool;

    modifier onlyCommissioner() {
        require(msg.sender == commissioner, "Not commissioner");
        _;
    }

    constructor() {
        commissioner = msg.sender;
        prizePool = FHE.asEuint64(0);
        FHE.allowThis(prizePool);
    }

    function registerTeam(string calldata name) public {
        require(draftOpen, "Draft not open");
        require(!teams[msg.sender].registered, "Already registered");
        teams[msg.sender] = Team({
            name: name,
            totalScore: FHE.asEuint32(0),
            prizeWon: FHE.asEuint64(0),
            registered: true
        });
        FHE.allowThis(teams[msg.sender].totalScore);
        FHE.allowThis(teams[msg.sender].prizeWon);
        teamList.push(msg.sender);
    }

    function openDraft() public onlyCommissioner { draftOpen = true; }
    function closeDraft() public onlyCommissioner { draftOpen = false; }

    function fundPrizePool(externalEuint64 amountStr, bytes calldata proof) public onlyCommissioner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        prizePool = FHE.add(prizePool, amount);
        FHE.allowThis(prizePool);
    }

    function updateScore(address teamOwner, externalEuint32 scoreStr, bytes calldata proof) public onlyCommissioner {
        require(teams[teamOwner].registered, "Not registered");
        euint32 score = FHE.fromExternal(scoreStr, proof);
        teams[teamOwner].totalScore = FHE.add(teams[teamOwner].totalScore, score);
        FHE.allowThis(teams[teamOwner].totalScore);
        FHE.allow(teams[teamOwner].totalScore, teamOwner);
    }

    function awardPrize(address teamOwner, externalEuint64 prizeStr, bytes calldata proof) public onlyCommissioner {
        euint64 prize = FHE.fromExternal(prizeStr, proof);
        ebool sufficient = FHE.ge(prizePool, prize);
        euint64 actual = FHE.select(sufficient, prize, prizePool);
        teams[teamOwner].prizeWon = FHE.add(teams[teamOwner].prizeWon, actual);
        prizePool = FHE.sub(prizePool, actual); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(teams[teamOwner].prizeWon);
        FHE.allow(teams[teamOwner].prizeWon, teamOwner);
        FHE.allowThis(prizePool);
    }

    function endSeason() public onlyCommissioner { seasonEnded = true; }

    function getTeamCount() public view returns (uint256) {
        return teamList.length;
    }
}
