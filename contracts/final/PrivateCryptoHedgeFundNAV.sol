// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCryptoHedgeFundNAV
/// @notice Crypto hedge fund with encrypted NAV per strategy bucket, encrypted PnL attribution,
///         encrypted investor redemption queues, and confidential high-watermark tracking.
contract PrivateCryptoHedgeFundNAV is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct StrategyBucket {
        string strategyName; // e.g. "L/S Equity", "Macro", "Arb", "Quant"
        euint64 navUSD;          // encrypted net asset value
        euint64 allocationBps;   // encrypted allocation percentage
        euint64 pnlUSD;          // encrypted realised PnL
        euint64 unrealisedPnL;   // encrypted unrealised PnL
        euint64 highWatermark;   // encrypted high-watermark for performance fee
        euint64 performanceFeeBps;
        bool active;
    }

    struct InvestorAccount {
        euint64 capitalUSD;      // encrypted invested capital
        euint64 sharesOwned;     // encrypted LP shares
        euint64 redemptionQueue; // encrypted pending redemption amount
        euint64 cumulativeFees;  // encrypted fees paid
        uint256 investedAt;
        bool exists;
    }

    struct RedemptionRequest {
        address investor;
        euint64 shareAmount;    // encrypted shares to redeem
        uint256 requestTime;
        bool processed;
    }

    mapping(uint256 => StrategyBucket) private strategies;
    mapping(address => InvestorAccount) private investors;
    mapping(uint256 => RedemptionRequest) private redemptions;
    uint256 public strategyCount;
    uint256 public redemptionCount;
    euint64 private _totalFundNAV;
    euint64 private _totalShares;
    euint64 private _managementFeeBps;
    mapping(address => bool) public isPortfolioManager;

    event StrategyCreated(uint256 indexed id, string name);
    event CapitalSubscribed(address indexed investor);
    event RedemptionRequested(uint256 indexed reqId, address indexed investor);
    event RedemptionProcessed(uint256 indexed reqId);
    event NAVRecalculated();

    constructor(externalEuint64 encMgmtFee, bytes memory proof) Ownable(msg.sender) {
        _managementFeeBps = FHE.fromExternal(encMgmtFee, proof);
        _totalFundNAV = FHE.asEuint64(0);
        _totalShares = FHE.asEuint64(0);
        FHE.allowThis(_managementFeeBps);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalShares);
        isPortfolioManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isPortfolioManager[m] = true; }

    function createStrategy(
        string calldata name,
        externalEuint64 encAlloc, bytes calldata aProof,
        externalEuint64 encPerfFee, bytes calldata fProof
    ) external returns (uint256 id) {
        require(isPortfolioManager[msg.sender], "Not PM");
        euint64 alloc = FHE.fromExternal(encAlloc, aProof);
        euint64 perfFee = FHE.fromExternal(encPerfFee, fProof);
        id = strategyCount++;
        strategies[id] = StrategyBucket({
            strategyName: name, navUSD: FHE.asEuint64(0),
            allocationBps: alloc, pnlUSD: FHE.asEuint64(0),
            unrealisedPnL: FHE.asEuint64(0),
            highWatermark: FHE.asEuint64(0),
            performanceFeeBps: perfFee, active: true
        });
        FHE.allowThis(strategies[id].navUSD);
        FHE.allowThis(strategies[id].allocationBps);
        FHE.allowThis(strategies[id].pnlUSD);
        FHE.allowThis(strategies[id].unrealisedPnL);
        FHE.allowThis(strategies[id].highWatermark);
        FHE.allowThis(strategies[id].performanceFeeBps);
        emit StrategyCreated(id, name);
    }

    function subscribe(externalEuint64 encCapital, bytes calldata proof, uint64 totalFundNAVPlaintext) external nonReentrant {
        euint64 capital = FHE.fromExternal(encCapital, proof);
        // Share price = totalNAV / totalShares (simplified: 1:1 at start)
        euint64 shares = FHE.isInitialized(_totalShares) ?
            (totalFundNAVPlaintext + 1 > 0 ? FHE.div(FHE.mul(capital, _totalShares), totalFundNAVPlaintext + 1) : capital) :
            capital;
        InvestorAccount storage inv = investors[msg.sender];
        if (!inv.exists) {
            inv.capitalUSD = FHE.asEuint64(0);
            inv.sharesOwned = FHE.asEuint64(0);
            inv.redemptionQueue = FHE.asEuint64(0);
            inv.cumulativeFees = FHE.asEuint64(0);
            inv.investedAt = block.timestamp;
            inv.exists = true;
            FHE.allowThis(inv.capitalUSD);
            FHE.allowThis(inv.sharesOwned);
            FHE.allowThis(inv.redemptionQueue);
            FHE.allowThis(inv.cumulativeFees);
        }
        inv.capitalUSD = FHE.add(inv.capitalUSD, capital);
        inv.sharesOwned = FHE.add(inv.sharesOwned, shares);
        _totalFundNAV = FHE.add(_totalFundNAV, capital);
        _totalShares = FHE.add(_totalShares, shares);
        FHE.allowThis(inv.capitalUSD);
        FHE.allow(inv.capitalUSD, msg.sender);
        FHE.allowThis(inv.sharesOwned);
        FHE.allow(inv.sharesOwned, msg.sender);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalShares);
        emit CapitalSubscribed(msg.sender);
    }

    function requestRedemption(externalEuint64 encShares, bytes calldata proof) external nonReentrant returns (uint256 reqId) {
        require(investors[msg.sender].exists, "Not investor");
        euint64 shares = FHE.fromExternal(encShares, proof);
        ebool hasSuf = FHE.le(shares, investors[msg.sender].sharesOwned);
        euint64 actual = FHE.select(hasSuf, shares, investors[msg.sender].sharesOwned);
        reqId = redemptionCount++;
        redemptions[reqId] = RedemptionRequest({ investor: msg.sender, shareAmount: actual, requestTime: block.timestamp, processed: false });
        FHE.allowThis(redemptions[reqId].shareAmount);
        // Update queue
        investors[msg.sender].redemptionQueue = FHE.add(investors[msg.sender].redemptionQueue, actual);
        FHE.allowThis(investors[msg.sender].redemptionQueue);
        FHE.allow(investors[msg.sender].redemptionQueue, msg.sender);
        emit RedemptionRequested(reqId, msg.sender);
    }

    function processRedemption(uint256 reqId, uint64 totalSharesPlaintext) external nonReentrant {
        require(isPortfolioManager[msg.sender], "Not PM");
        RedemptionRequest storage req = redemptions[reqId];
        require(!req.processed, "Already processed");
        InvestorAccount storage inv = investors[req.investor];
        // NAV per share = totalNAV / totalShares
        euint64 navPerShare = totalSharesPlaintext + 1 > 0
            ? FHE.div(_totalFundNAV, totalSharesPlaintext + 1)
            : FHE.asEuint64(0);
        euint64 proceeds = FHE.mul(navPerShare, req.shareAmount);
        // Deduct performance fee above HWM
        inv.sharesOwned = FHE.sub(inv.sharesOwned, req.shareAmount);
        _totalShares = FHE.sub(_totalShares, req.shareAmount);
        _totalFundNAV = FHE.sub(_totalFundNAV, proceeds);
        inv.redemptionQueue = FHE.sub(inv.redemptionQueue, req.shareAmount);
        req.processed = true;
        FHE.allowThis(inv.sharesOwned);
        FHE.allow(inv.sharesOwned, req.investor);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalShares);
        FHE.allow(proceeds, req.investor);
        emit RedemptionProcessed(reqId);
    }

    function updateStrategyNAV(
        uint256 stratId,
        externalEuint64 encNewNAV, bytes calldata nProof,
        externalEuint64 encUnrealPnL, bytes calldata pProof
    ) external {
        require(isPortfolioManager[msg.sender], "Not PM");
        StrategyBucket storage s = strategies[stratId];
        _totalFundNAV = FHE.sub(_totalFundNAV, s.navUSD);
        s.navUSD = FHE.fromExternal(encNewNAV, nProof);
        s.unrealisedPnL = FHE.fromExternal(encUnrealPnL, pProof);
        _totalFundNAV = FHE.add(_totalFundNAV, s.navUSD);
        // Update high watermark
        ebool newHWM = FHE.gt(s.navUSD, s.highWatermark);
        s.highWatermark = FHE.select(newHWM, s.navUSD, s.highWatermark);
        FHE.allowThis(s.navUSD);
        FHE.allowThis(s.unrealisedPnL);
        FHE.allowThis(s.highWatermark);
        FHE.allowThis(_totalFundNAV);
        emit NAVRecalculated();
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}