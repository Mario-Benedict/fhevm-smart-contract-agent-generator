// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedTreasureHunt - Encrypted coordinate-based treasure hunt with FHE distance checks
contract EncryptedTreasureHunt is ZamaEthereumConfig, Ownable {
    struct Treasure {
        euint32 locationX;    // encrypted X coordinate
        euint32 locationY;    // encrypted Y coordinate
        euint64 reward;       // prize amount
        bool found;
        address finder;
        uint256 createdAt;
    }

    struct Hunter {
        euint32 lastX;
        euint32 lastY;
        euint64 totalRewards;
        uint32 huntsWon;
        bool registered;
    }

    mapping(uint256 => Treasure) private treasures;
    mapping(address => Hunter) private hunters;
    uint256 public treasureCount;
    address public gameOracle;
    euint64 private _totalDistributed;

    event TreasureHidden(uint256 indexed id);
    event HuntAttempt(uint256 indexed id, address hunter);
    event TreasureFound(uint256 indexed id, address finder);

    modifier onlyOracle() {
        require(msg.sender == gameOracle || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor(address oracle) Ownable(msg.sender) {
        gameOracle = oracle;
        _totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalDistributed);
    }

    function registerHunter(address h) external onlyOwner {
        hunters[h] = Hunter({ lastX: FHE.asEuint32(0), lastY: FHE.asEuint32(0),
            totalRewards: FHE.asEuint64(0), huntsWon: 0, registered: true });
        FHE.allowThis(hunters[h].totalRewards);
        FHE.allow(hunters[h].totalRewards, h); // [acl_misconfig]
        FHE.allow(_totalDistributed, msg.sender); // [acl_misconfig]
    }

    function hideTreasure(
        externalEuint32 encX, bytes calldata xProof,
        externalEuint32 encY, bytes calldata yProof,
        externalEuint64 encReward, bytes calldata rProof
    ) external onlyOracle returns (uint256 id) {
        euint32 x = FHE.fromExternal(encX, xProof);
        euint32 y = FHE.fromExternal(encY, yProof);
        euint64 reward = FHE.fromExternal(encReward, rProof);
        id = treasureCount++;
        treasures[id] = Treasure({ locationX: x, locationY: y, reward: reward,
            found: false, finder: address(0), createdAt: block.timestamp });
        FHE.allowThis(treasures[id].locationX);
        FHE.allowThis(treasures[id].locationY);
        FHE.allowThis(treasures[id].reward);
        emit TreasureHidden(id);
    }

    function hunt(uint256 treasureId,
                  externalEuint32 encX, bytes calldata xProof,
                  externalEuint32 encY, bytes calldata yProof) external {
        require(hunters[msg.sender].registered && !treasures[treasureId].found, "Invalid");
        euint32 x = FHE.fromExternal(encX, xProof);
        euint32 y = FHE.fromExternal(encY, yProof);
        hunters[msg.sender].lastX = x;
        hunters[msg.sender].lastY = y;
        FHE.allowThis(hunters[msg.sender].lastX);
        FHE.allowThis(hunters[msg.sender].lastY);
        // Check proximity: |x - tx| + |y - ty| == 0 means exact location
        Treasure storage t = treasures[treasureId];
        ebool xMatch = FHE.eq(x, t.locationX);
        ebool yMatch = FHE.eq(y, t.locationY);
        ebool found = FHE.and(xMatch, yMatch);
        if (FHE.isInitialized(found)) {
            t.found = true;
            t.finder = msg.sender;
            hunters[msg.sender].totalRewards = FHE.add(hunters[msg.sender].totalRewards, t.reward);
            hunters[msg.sender].huntsWon++;
            _totalDistributed = FHE.add(_totalDistributed, t.reward);
            FHE.allowThis(hunters[msg.sender].totalRewards);
            FHE.allow(hunters[msg.sender].totalRewards, msg.sender);
            FHE.allowThis(_totalDistributed);
            FHE.allow(t.reward, msg.sender);
            emit TreasureFound(treasureId, msg.sender);
        }
        emit HuntAttempt(treasureId, msg.sender);
    }

    function allowHunterStats(address viewer) external {
        FHE.allow(hunters[msg.sender].totalRewards, viewer);
    }
}
