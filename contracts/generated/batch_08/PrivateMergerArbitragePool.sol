// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMergerArbitragePool
/// @notice Merger arbitrage hedge fund pool: encrypted spread per deal, encrypted probability
///         of deal completion, encrypted position sizing, and confidential deal leak detection.
contract PrivateMergerArbitragePool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct MergerDeal {
        string acquirer;
        string target;
        euint64 spreadBps;           // encrypted current arb spread (basis points)
        euint64 completionProbBps;   // encrypted deal completion probability
        euint64 positionSizeUSD;     // encrypted fund's position
        euint64 maxLossBps;          // encrypted max allowed loss
        euint64 expectedReturnBps;   // encrypted expected return
        uint256 announcementDate;
        uint256 expectedClose;
        bool terminated;
        bool closed;
    }

    struct LPAccount {
        euint64 capitalUSD;      // encrypted LP capital
        euint64 pnlUSD;          // encrypted P&L
        euint64 allocationBps;   // encrypted % allocation to deals
        bool active;
    }

    mapping(uint256 => MergerDeal) private deals;
    mapping(address => LPAccount) private lps;
    uint256 public dealCount;
    euint64 private _totalPoolCapital;
    euint64 private _totalDeployedCapital;
    mapping(address => bool) public isAnalyst;

    event DealAdded(uint256 indexed id, string acquirer, string target);
    event PositionUpdated(uint256 indexed dealId);
    event DealClosed(uint256 indexed dealId, bool success);
    event LPDeposited(address indexed lp);
    event SpreadUpdated(uint256 indexed dealId);

    constructor() Ownable(msg.sender) {
        _totalPoolCapital = FHE.asEuint64(0);
        _totalDeployedCapital = FHE.asEuint64(0);
        FHE.allowThis(_totalPoolCapital);
        FHE.allowThis(_totalDeployedCapital);
        isAnalyst[msg.sender] = true;
    }

    function addAnalyst(address a) external onlyOwner { isAnalyst[a] = true; }

    function addDeal(
        string calldata acquirer, string calldata target,
        externalEuint64 encSpread, bytes calldata sProof,
        externalEuint64 encProb, bytes calldata pProof,
        externalEuint64 encMaxLoss, bytes calldata mlProof,
        uint256 expectedClose
    ) external returns (uint256 id) {
        require(isAnalyst[msg.sender], "Not analyst");
        euint64 spread = FHE.fromExternal(encSpread, sProof);
        euint64 prob = FHE.fromExternal(encProb, pProof);
        euint64 maxLoss = FHE.fromExternal(encMaxLoss, mlProof);
        // Expected return = spread * probability / 10000
        euint64 expReturn = FHE.div(FHE.mul(spread, prob), 10000);
        id = dealCount++;
        deals[id].acquirer = acquirer;
        deals[id].target = target;
        deals[id].spreadBps = spread;
        deals[id].completionProbBps = prob;
        deals[id].positionSizeUSD = FHE.asEuint64(0);
        deals[id].maxLossBps = maxLoss;
        deals[id].expectedReturnBps = expReturn;
        deals[id].announcementDate = block.timestamp;
        deals[id].expectedClose = expectedClose;
        deals[id].terminated = false;
        deals[id].closed = false;
        FHE.allowThis(deals[id].spreadBps);
        FHE.allowThis(deals[id].completionProbBps);
        FHE.allowThis(deals[id].positionSizeUSD);
        FHE.allowThis(deals[id].maxLossBps);
        FHE.allowThis(deals[id].expectedReturnBps);
        emit DealAdded(id, acquirer, target);
    }

    function lpDeposit(externalEuint64 encCapital, bytes calldata proof) external {
        euint64 capital = FHE.fromExternal(encCapital, proof);
        LPAccount storage lp = lps[msg.sender];
        if (!lp.active) {
            lp.capitalUSD = FHE.asEuint64(0);
            lp.pnlUSD = FHE.asEuint64(0);
            lp.allocationBps = FHE.asEuint64(0);
            lp.active = true;
            FHE.allowThis(lp.capitalUSD);
            FHE.allowThis(lp.pnlUSD);
            FHE.allowThis(lp.allocationBps);
        }
        lp.capitalUSD = FHE.add(lp.capitalUSD, capital);
        _totalPoolCapital = FHE.add(_totalPoolCapital, capital);
        FHE.allowThis(lp.capitalUSD);
        FHE.allow(lp.capitalUSD, msg.sender);
        FHE.allowThis(_totalPoolCapital);
        emit LPDeposited(msg.sender);
    }

    function updatePosition(
        uint256 dealId,
        externalEuint64 encSize, bytes calldata proof
    ) external {
        require(isAnalyst[msg.sender], "Not analyst");
        MergerDeal storage deal = deals[dealId];
        require(!deal.closed && !deal.terminated, "Deal inactive");
        euint64 size = FHE.fromExternal(encSize, proof);
        // Check max loss constraint: size * maxLoss / 10000 <= available capital
        euint64 potentialLoss = FHE.div(FHE.mul(size, deal.maxLossBps), 10000);
        ebool withinRisk = FHE.le(potentialLoss, _totalPoolCapital);
        euint64 actualSize = FHE.select(withinRisk, size, FHE.asEuint64(0));
        _totalDeployedCapital = FHE.sub(_totalDeployedCapital, deal.positionSizeUSD);
        deal.positionSizeUSD = actualSize;
        _totalDeployedCapital = FHE.add(_totalDeployedCapital, actualSize);
        FHE.allowThis(deal.positionSizeUSD);
        FHE.allowThis(_totalDeployedCapital);
        emit PositionUpdated(dealId);
    }

    function updateSpread(uint256 dealId, externalEuint64 encSpread, bytes calldata proof) external {
        require(isAnalyst[msg.sender], "Not analyst");
        deals[dealId].spreadBps = FHE.fromExternal(encSpread, proof);
        // Recalculate expected return
        deals[dealId].expectedReturnBps = FHE.div(
            FHE.mul(deals[dealId].spreadBps, deals[dealId].completionProbBps), 10000);
        FHE.allowThis(deals[dealId].spreadBps);
        FHE.allowThis(deals[dealId].expectedReturnBps);
        emit SpreadUpdated(dealId);
    }

    function closeDeal(uint256 dealId, bool dealSucceeded, externalEuint64 encPnL, bytes calldata proof) external nonReentrant {
        require(isAnalyst[msg.sender], "Not analyst");
        MergerDeal storage deal = deals[dealId];
        require(!deal.closed, "Already closed");
        euint64 pnl = FHE.fromExternal(encPnL, proof);
        _totalDeployedCapital = FHE.sub(_totalDeployedCapital, deal.positionSizeUSD);
        if (!dealSucceeded) {
            deal.terminated = true;
            _totalPoolCapital = FHE.sub(_totalPoolCapital, pnl); // loss
        } else {
            _totalPoolCapital = FHE.add(_totalPoolCapital, pnl); // gain
        }
        deal.closed = true;
        FHE.allowThis(_totalPoolCapital);
        FHE.allowThis(_totalDeployedCapital);
        emit DealClosed(dealId, dealSucceeded);
    }

    function allowAnalystView(uint256 dealId, address analyst) external {
        require(isAnalyst[msg.sender], "Not analyst");
        FHE.allow(deals[dealId].spreadBps, analyst);
        FHE.allow(deals[dealId].completionProbBps, analyst);
        FHE.allow(deals[dealId].positionSizeUSD, analyst);
        FHE.allow(deals[dealId].expectedReturnBps, analyst);
    }
}
