// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePredictionMarket - Encrypted position-taking on binary future outcomes
contract PrivatePredictionMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Market {
        string question;
        string resolution_source;
        uint256 closeTime;
        uint256 resolutionTime;
        euint64 yesPool;
        euint64 noPool;
        euint64 totalPool;
        bool resolved;
        bool outcome; // true=YES won
        uint16 feeBps;
    }

    struct Position {
        euint64 yesAmount;
        euint64 noAmount;
        bool claimed;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => Position)) private positions;
    uint256 public marketCount;

    event MarketCreated(uint256 indexed marketId, string question);
    event PositionTaken(uint256 indexed marketId, address indexed trader);
    event MarketResolved(uint256 indexed marketId, bool outcome);
    event WinningsClaimed(uint256 indexed marketId, address indexed trader);

    constructor() Ownable(msg.sender) {}

    function createMarket(
        string calldata question,
        string calldata resolutionSource,
        uint256 closeWindow,
        uint256 resolutionDelay,
        uint16 feeBps
    ) external onlyOwner returns (uint256 marketId) {
        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.question = question;
        m.resolution_source = resolutionSource;
        m.closeTime = block.timestamp + closeWindow;
        m.resolutionTime = block.timestamp + closeWindow + resolutionDelay;
        m.yesPool = FHE.asEuint64(0);
        m.noPool = FHE.asEuint64(0);
        m.totalPool = FHE.asEuint64(0);
        m.feeBps = feeBps;
        FHE.allowThis(m.yesPool);
        FHE.allowThis(m.noPool);
        FHE.allowThis(m.totalPool);
        emit MarketCreated(marketId, question);
    }

    function takePosition(
        uint256 marketId,
        externalEbool encSide,
        bytes calldata sideProof,
        externalEuint64 encAmount,
        bytes calldata amountProof
    ) external nonReentrant {
        Market storage m = markets[marketId];
        require(block.timestamp <= m.closeTime, "Market closed");
        require(!m.resolved, "Resolved");

        ebool side = FHE.fromExternal(encSide, sideProof);
        euint64 amount = FHE.fromExternal(encAmount, amountProof);
        Position storage p = positions[marketId][msg.sender];

        p.yesAmount = FHE.add(p.yesAmount, FHE.select(side, amount, FHE.asEuint64(0)));
        p.noAmount = FHE.add(p.noAmount, FHE.select(FHE.not(side), amount, FHE.asEuint64(0)));
        m.yesPool = FHE.add(m.yesPool, FHE.select(side, amount, FHE.asEuint64(0)));
        m.noPool = FHE.add(m.noPool, FHE.select(FHE.not(side), amount, FHE.asEuint64(0)));
        m.totalPool = FHE.add(m.totalPool, amount);

        FHE.allowThis(p.yesAmount);
        FHE.allowThis(p.noAmount);
        FHE.allowThis(m.yesPool);
        FHE.allowThis(m.noPool);
        FHE.allowThis(m.totalPool);
        FHE.allow(p.yesAmount, msg.sender);
        FHE.allow(p.noAmount, msg.sender);
        emit PositionTaken(marketId, msg.sender);
    }

    function resolveMarket(uint256 marketId, bool outcome) external onlyOwner {
        Market storage m = markets[marketId];
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(!m.resolved, "Already resolved");
        m.resolved = true;
        m.outcome = outcome;
        FHE.allow(m.yesPool, owner());
        FHE.allow(m.noPool, owner());
        FHE.allow(m.totalPool, owner());
        emit MarketResolved(marketId, outcome);
    }

    function claimWinnings(uint256 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        require(m.resolved, "Not resolved");
        Position storage p = positions[marketId][msg.sender];
        require(!p.claimed, "Already claimed");
        p.claimed = true;

        euint64 stake = m.outcome ? p.yesAmount : p.noAmount;
        euint64 winningPool = m.outcome ? m.yesPool : m.noPool;
        euint64 fee = FHE.div(FHE.mul(m.totalPool, FHE.asEuint64(m.feeBps)), 10000);
        euint64 payout = FHE.div(FHE.mul(stake, FHE.sub(m.totalPool, fee)), winningPool);

        FHE.allowTransient(payout, msg.sender);
        emit WinningsClaimed(marketId, msg.sender);
    }
}
