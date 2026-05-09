// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCrossChainBridgeFeeOptimizer
/// @notice Encrypted cross-chain bridge with confidential fee routing.
///         Bridge fees, user balances, and route selection are encrypted
///         to prevent MEV extraction and front-running on bridge transactions.
contract PrivateCrossChainBridgeFeeOptimizer is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ChainId { Ethereum, BNBChain, Polygon, Arbitrum, Optimism, Avalanche, Base, Solana }
    enum BridgeStatus { Pending, Relaying, Completed, Failed, Refunded }

    struct BridgeRoute {
        ChainId sourceChain;
        ChainId destChain;
        euint64 baseFeeUSD;             // encrypted base bridge fee
        euint32 feeRateBps;             // encrypted % fee on amount
        euint64 minAmountUSD;           // encrypted minimum transfer
        euint64 maxAmountUSD;           // encrypted maximum transfer
        euint32 estimatedMinutes;       // encrypted settlement time
        euint64 liquidityAvailableUSD;  // encrypted route liquidity
        bool active;
    }

    struct BridgeTransaction {
        uint256 txId;
        address sender;
        address recipient;
        ChainId sourceChain;
        ChainId destChain;
        euint64 grossAmountUSD;         // encrypted transfer amount
        euint64 feeDeductedUSD;         // encrypted fee charged
        euint64 netAmountUSD;           // encrypted amount received
        euint64 mevSavedUSD;            // encrypted MEV saving vs public
        BridgeStatus status;
        uint256 initiatedAt;
        uint256 completedAt;
    }

    struct UserBridgeBalance {
        euint64 pendingOutbound;        // encrypted outgoing locked
        euint64 totalBridged;           // encrypted lifetime volume
        euint64 totalFeePaid;           // encrypted total fees
        euint64 totalMEVSaved;          // encrypted MEV savings
        uint32 txCount;
    }

    mapping(uint256 => BridgeRoute) private routes;
    mapping(uint256 => BridgeTransaction) private transactions;
    mapping(address => UserBridgeBalance) private userBalances;
    mapping(address => bool) public isRelayer;

    uint256 public routeCount;
    uint256 public txCount;
    euint64 private _totalVolumeUSD;
    euint64 private _totalFeesCollected;
    euint64 private _totalMEVProtected;

    event RouteCreated(uint256 indexed routeId, ChainId source, ChainId dest);
    event BridgeInitiated(uint256 indexed txId, address sender, ChainId dest);
    event BridgeCompleted(uint256 indexed txId);
    event BridgeFailed(uint256 indexed txId);
    event LiquidityUpdated(uint256 indexed routeId);

    modifier onlyRelayer() {
        require(isRelayer[msg.sender] || msg.sender == owner(), "Not relayer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVolumeUSD = FHE.asEuint64(0);
        _totalFeesCollected = FHE.asEuint64(0);
        _totalMEVProtected = FHE.asEuint64(0);
        FHE.allowThis(_totalVolumeUSD);
        FHE.allowThis(_totalFeesCollected);
        FHE.allowThis(_totalMEVProtected);
        isRelayer[msg.sender] = true;
    }

    function addRelayer(address r) external onlyOwner { isRelayer[r] = true; }

    function createRoute(
        ChainId sourceChain,
        ChainId destChain,
        externalEuint64 encBaseFee, bytes calldata baseProof,
        externalEuint32 encFeeRate, bytes calldata rateProof,
        externalEuint64 encMin, bytes calldata minProof,
        externalEuint64 encMax, bytes calldata maxProof,
        externalEuint64 encLiquidity, bytes calldata liqProof
    ) external onlyOwner returns (uint256 routeId) {
        routeId = routeCount++;
        BridgeRoute storage r = routes[routeId];
        r.sourceChain = sourceChain;
        r.destChain = destChain;
        r.baseFeeUSD = FHE.fromExternal(encBaseFee, baseProof);
        r.feeRateBps = FHE.fromExternal(encFeeRate, rateProof);
        r.minAmountUSD = FHE.fromExternal(encMin, minProof);
        r.maxAmountUSD = FHE.fromExternal(encMax, maxProof);
        r.estimatedMinutes = FHE.asEuint32(15);
        r.liquidityAvailableUSD = FHE.fromExternal(encLiquidity, liqProof);
        r.active = true;
        FHE.allowThis(r.baseFeeUSD); FHE.allowThis(r.feeRateBps);
        FHE.allowThis(r.minAmountUSD); FHE.allowThis(r.maxAmountUSD);
        FHE.allowThis(r.liquidityAvailableUSD);
        emit RouteCreated(routeId, sourceChain, destChain);
    }

    function initiateBridge(
        uint256 routeId,
        address recipient,
        externalEuint64 encAmount, bytes calldata amtProof,
        externalEuint64 encMEVSaved, bytes calldata mevProof
    ) external nonReentrant returns (uint256 txId) {
        BridgeRoute storage route = routes[routeId];
        require(route.active, "Route not active");
        euint64 grossAmt = FHE.fromExternal(encAmount, amtProof);
        euint64 mevSaved = FHE.fromExternal(encMEVSaved, mevProof);
        // Compute fee: baseFee + (amount * feeRate / 10000)
        euint64 propFee = FHE.div(FHE.mul(grossAmt, FHE.asEuint64(route.feeRateBps)), 10000);
        euint64 totalFee = FHE.add(route.baseFeeUSD, propFee);
        euint64 netAmt = FHE.sub(grossAmt, totalFee);
        // Validate amount
        ebool aboveMin = FHE.ge(grossAmt, route.minAmountUSD);
        ebool belowMax = FHE.le(grossAmt, route.maxAmountUSD);
        ebool hasLiq = FHE.le(grossAmt, route.liquidityAvailableUSD);
        euint64 effectiveNet = FHE.select(FHE.and(FHE.and(aboveMin, belowMax), hasLiq), netAmt, FHE.asEuint64(0));
        txId = txCount++;
        BridgeTransaction storage t = transactions[txId];
        t.txId = txId;
        t.sender = msg.sender;
        t.recipient = recipient;
        t.sourceChain = route.sourceChain;
        t.destChain = route.destChain;
        t.grossAmountUSD = grossAmt;
        t.feeDeductedUSD = totalFee;
        t.netAmountUSD = effectiveNet;
        t.mevSavedUSD = mevSaved;
        t.status = BridgeStatus.Pending;
        t.initiatedAt = block.timestamp;
        route.liquidityAvailableUSD = FHE.sub(route.liquidityAvailableUSD, grossAmt);
        UserBridgeBalance storage ub = userBalances[msg.sender];
        ub.pendingOutbound = FHE.add(ub.pendingOutbound, grossAmt);
        ub.totalBridged = FHE.add(ub.totalBridged, grossAmt);
        ub.totalFeePaid = FHE.add(ub.totalFeePaid, totalFee);
        ub.totalMEVSaved = FHE.add(ub.totalMEVSaved, mevSaved);
        ub.txCount++;
        _totalVolumeUSD = FHE.add(_totalVolumeUSD, grossAmt);
        _totalFeesCollected = FHE.add(_totalFeesCollected, totalFee);
        _totalMEVProtected = FHE.add(_totalMEVProtected, mevSaved);
        FHE.allowThis(t.grossAmountUSD); FHE.allow(t.grossAmountUSD, msg.sender);
        FHE.allowThis(t.feeDeductedUSD); FHE.allow(t.feeDeductedUSD, msg.sender);
        FHE.allowThis(t.netAmountUSD); FHE.allow(t.netAmountUSD, msg.sender); FHE.allow(t.netAmountUSD, recipient);
        FHE.allowThis(t.mevSavedUSD); FHE.allow(t.mevSavedUSD, msg.sender);
        FHE.allowThis(route.liquidityAvailableUSD);
        FHE.allowThis(ub.pendingOutbound); FHE.allowThis(ub.totalBridged); FHE.allow(ub.totalBridged, msg.sender);
        FHE.allowThis(ub.totalFeePaid); FHE.allow(ub.totalFeePaid, msg.sender);
        FHE.allowThis(ub.totalMEVSaved); FHE.allow(ub.totalMEVSaved, msg.sender);
        FHE.allowThis(_totalVolumeUSD); FHE.allowThis(_totalFeesCollected); FHE.allowThis(_totalMEVProtected);
        emit BridgeInitiated(txId, msg.sender, route.destChain);
    }

    function completeBridge(uint256 txId) external onlyRelayer {
        BridgeTransaction storage t = transactions[txId];
        require(t.status == BridgeStatus.Pending || t.status == BridgeStatus.Relaying, "Wrong status");
        t.status = BridgeStatus.Completed;
        t.completedAt = block.timestamp;
        userBalances[t.sender].pendingOutbound = FHE.sub(userBalances[t.sender].pendingOutbound, t.grossAmountUSD);
        FHE.allowThis(userBalances[t.sender].pendingOutbound);
        emit BridgeCompleted(txId);
    }

    function failBridge(uint256 txId) external onlyRelayer {
        transactions[txId].status = BridgeStatus.Failed;
        emit BridgeFailed(txId);
    }

    function allowBridgeStats(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeUSD, viewer);
        FHE.allow(_totalFeesCollected, viewer);
        FHE.allow(_totalMEVProtected, viewer);
    }
}
