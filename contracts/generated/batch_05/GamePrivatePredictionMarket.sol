// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GamePrivatePredictionMarket
/// @notice Prediction market where question outcomes and liquidity positions are encrypted.
///         Market makers cannot see aggregate positions to prevent liquidity manipulation.
contract GamePrivatePredictionMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Market {
        string question;
        uint256 resolutionTime;
        bool resolved;
        bool outcome; // true = YES won
        euint64 yesPool;
        euint64 noPool;
        euint64 feePool;
        euint16 feeBps;
    }

    struct Position {
        euint64 yesShares;
        euint64 noShares;
        bool settled;
    }

    mapping(uint256 => Market) private markets;
    uint256 public marketCount;
    mapping(uint256 => mapping(address => Position)) private positions;
    mapping(uint256 => address[]) private traders;

    event MarketCreated(uint256 indexed id, string question);
    event PositionTaken(uint256 indexed marketId, address trader);
    event MarketResolved(uint256 indexed id, bool outcome);
    event RewardClaimed(uint256 indexed marketId, address trader);

    constructor() Ownable(msg.sender) {}

    function createMarket(
        string calldata question,
        uint256 resolutionTime,
        externalEuint16 encFee, bytes calldata proof
    ) external onlyOwner returns (uint256 id) {
        id = marketCount++;
        markets[id].question = question;
        markets[id].resolutionTime = resolutionTime;
        markets[id].feeBps = FHE.fromExternal(encFee, proof);
        markets[id].yesPool = FHE.asEuint64(0);
        markets[id].noPool = FHE.asEuint64(0);
        markets[id].feePool = FHE.asEuint64(0);
        FHE.allowThis(markets[id].feeBps);
        FHE.allowThis(markets[id].yesPool);
        FHE.allowThis(markets[id].noPool);
        FHE.allowThis(markets[id].feePool);
        emit MarketCreated(id, question);
    }

    function buyYes(uint256 marketId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Market storage m = markets[marketId];
        require(!m.resolved && block.timestamp < m.resolutionTime, "Closed");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 fee = FHE.div(FHE.mul(amount, FHE.asEuint64(m.feeBps)), 10000);
        euint64 net = FHE.sub(amount, fee);
        positions[marketId][msg.sender].yesShares = FHE.add(positions[marketId][msg.sender].yesShares, net);
        m.yesPool = FHE.add(m.yesPool, net);
        m.feePool = FHE.add(m.feePool, fee);
        FHE.allowThis(positions[marketId][msg.sender].yesShares);
        FHE.allow(positions[marketId][msg.sender].yesShares, msg.sender);
        FHE.allowThis(m.yesPool);
        FHE.allowThis(m.feePool);
        traders[marketId].push(msg.sender);
        emit PositionTaken(marketId, msg.sender);
    }

    function buyNo(uint256 marketId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Market storage m = markets[marketId];
        require(!m.resolved && block.timestamp < m.resolutionTime, "Closed");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 fee = FHE.div(FHE.mul(amount, FHE.asEuint64(m.feeBps)), 10000);
        euint64 net = FHE.sub(amount, fee);
        positions[marketId][msg.sender].noShares = FHE.add(positions[marketId][msg.sender].noShares, net);
        m.noPool = FHE.add(m.noPool, net);
        m.feePool = FHE.add(m.feePool, fee);
        FHE.allowThis(positions[marketId][msg.sender].noShares);
        FHE.allow(positions[marketId][msg.sender].noShares, msg.sender);
        FHE.allowThis(m.noPool);
        FHE.allowThis(m.feePool);
        emit PositionTaken(marketId, msg.sender);
    }

    function resolveMarket(uint256 marketId, bool yesWon) external onlyOwner {
        Market storage m = markets[marketId];
        require(!m.resolved && block.timestamp >= m.resolutionTime, "Cannot resolve");
        m.resolved = true;
        m.outcome = yesWon;
        emit MarketResolved(marketId, yesWon);
    }

    function claimReward(uint256 marketId, uint64 winningPoolPlaintext) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolved, "Not resolved");
        Position storage pos = positions[marketId][msg.sender];
        require(!pos.settled, "Already settled");
        pos.settled = true;
        euint64 totalPool = FHE.add(m.yesPool, m.noPool);
        if (m.outcome) {
            // YES won: payout proportional to YES shares
            euint64 payout = winningPoolPlaintext > 0
                ? FHE.div(FHE.mul(pos.yesShares, totalPool), winningPoolPlaintext)
                : FHE.asEuint64(0);
            FHE.allow(payout, msg.sender);
        } else {
            euint64 payout = winningPoolPlaintext > 0
                ? FHE.div(FHE.mul(pos.noShares, totalPool), winningPoolPlaintext)
                : FHE.asEuint64(0);
            FHE.allow(payout, msg.sender);
        }
        emit RewardClaimed(marketId, msg.sender);
    }

    function allowPositionData(uint256 marketId, address viewer) external {
        FHE.allow(positions[marketId][msg.sender].yesShares, viewer);
        FHE.allow(positions[marketId][msg.sender].noShares, viewer);
    }
}
