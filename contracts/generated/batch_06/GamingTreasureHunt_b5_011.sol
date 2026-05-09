// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingTreasureHunt_b5_011 - Encrypted treasure hunt with hidden prize locations
contract GamingTreasureHunt_b5_011 is ZamaEthereumConfig {
    address public organizer;
    bool public huntActive;

    struct Treasure {
        euint8 locationX;
        euint8 locationY;
        euint64 reward;
        bool claimed;
    }

    Treasure[] private treasures;
    mapping(address => uint256) public claimedCount;
    euint64 private totalPrizePool;

    modifier onlyOrganizer() {
        require(msg.sender == organizer, "Not organizer");
        _;
    }

    constructor() {
        organizer = msg.sender;
        totalPrizePool = FHE.asEuint64(0);
        FHE.allowThis(totalPrizePool);
    }

    function hideTreasure(
        externalEuint8 xStr, bytes calldata xProof,
        externalEuint8 yStr, bytes calldata yProof,
        externalEuint64 rewardStr, bytes calldata rewardProof
    ) public onlyOrganizer {
        euint8 x = FHE.fromExternal(xStr, xProof);
        euint8 y = FHE.fromExternal(yStr, yProof);
        euint64 reward = FHE.fromExternal(rewardStr, rewardProof);
        uint256 id = treasures.length;
        treasures.push(Treasure({ locationX: x, locationY: y, reward: reward, claimed: false }));
        FHE.allowThis(treasures[id].locationX);
        FHE.allowThis(treasures[id].locationY);
        FHE.allowThis(treasures[id].reward);
        totalPrizePool = FHE.add(totalPrizePool, reward);
        FHE.allowThis(totalPrizePool);
    }

    function startHunt() public onlyOrganizer { huntActive = true; }
    function endHunt() public onlyOrganizer { huntActive = false; }

    function dig(uint256 treasureId, uint8 guessX, uint8 guessY) public {
        require(huntActive, "Hunt not active");
        require(treasureId < treasures.length, "Invalid treasure");
        Treasure storage t = treasures[treasureId];
        require(!t.claimed, "Already claimed");

        ebool matchX = FHE.eq(t.locationX, FHE.asEuint8(guessX));
        ebool matchY = FHE.eq(t.locationY, FHE.asEuint8(guessY));
        ebool found = FHE.and(matchX, matchY);

        euint64 payout = FHE.select(found, t.reward, FHE.asEuint64(0));
        // Note: in practice, found would need decryption to mark claimed
        t.reward = FHE.select(found, FHE.asEuint64(0), t.reward);
        FHE.allowThis(t.reward);
        claimedCount[msg.sender]++;
        FHE.allow(payout, msg.sender);
        FHE.allowThis(payout);
    }

    function getTreasureCount() public view returns (uint256) {
        return treasures.length;
    }
}
