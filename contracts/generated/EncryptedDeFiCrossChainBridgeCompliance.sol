// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDeFiCrossChainBridgeCompliance
/// @notice Cross-chain bridge with encrypted transaction volumes, compliance scores,
///         liquidity pool reserves, and fee distributions.
contract EncryptedDeFiCrossChainBridgeCompliance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ChainId { ETHEREUM, POLYGON, ARBITRUM, OPTIMISM, AVALANCHE, BSC, SOLANA }
    enum BridgeStatus { ACTIVE, PAUSED, MAINTENANCE, DEPRECATED }

    struct BridgeLane {
        ChainId sourceChain;
        ChainId destChain;
        string tokenSymbol;
        euint64 liquidityReserveUSD;   // encrypted liquidity
        euint64 totalVolumeBridged;    // encrypted lifetime volume
        euint64 dailyVolumeCap;        // encrypted daily limit
        euint64 todayVolume;           // encrypted today's volume
        euint64 feeBps;                // encrypted bridge fee
        euint64 totalFeesEarned;       // encrypted fee revenue
        euint32 txCount;               // encrypted tx count
        euint8  complianceScore;       // encrypted AML compliance 0-100
        BridgeStatus status;
    }

    struct BridgeTx {
        uint256 laneId;
        address sender;
        address recipient;
        euint64 amountUSD;             // encrypted amount
        euint64 feeUSD;                // encrypted fee charged
        euint64 receivedAmountUSD;     // encrypted net received
        uint256 initiatedAt;
        bool completed;
        bool flagged;
    }

    mapping(uint256 => BridgeLane) private lanes;
    mapping(uint256 => BridgeTx) private txs;
    mapping(address => bool) public isBridgeOperator;
    mapping(address => bool) public isComplianceAgent;
    uint256 public laneCount;
    uint256 public txCount;
    euint64 private _totalBridgeVolume;
    euint64 private _totalBridgeFees;
    euint32 private _flaggedTxCount;

    event LaneCreated(uint256 indexed laneId, ChainId src, ChainId dst);
    event BridgeTxInitiated(uint256 indexed txId, uint256 laneId);
    event BridgeTxCompleted(uint256 indexed txId);
    event TxFlagged(uint256 indexed txId);

    constructor() Ownable(msg.sender) {
        _totalBridgeVolume = FHE.asEuint64(0);
        _totalBridgeFees = FHE.asEuint64(0);
        _flaggedTxCount = FHE.asEuint32(0);
        FHE.allowThis(_totalBridgeVolume);
        FHE.allowThis(_totalBridgeFees);
        FHE.allowThis(_flaggedTxCount);
        isBridgeOperator[msg.sender] = true;
        isComplianceAgent[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isBridgeOperator[op] = true; }
    function addComplianceAgent(address ca) external onlyOwner { isComplianceAgent[ca] = true; }

    function createLane(
        ChainId src, ChainId dst, string calldata token,
        externalEuint64 encLiquidity, bytes calldata liqProof,
        externalEuint64 encDailyCap,  bytes calldata dcProof,
        externalEuint64 encFee,       bytes calldata fProof
    ) external returns (uint256 laneId) {
        require(isBridgeOperator[msg.sender], "Not operator");
        euint64 liquidity = FHE.fromExternal(encLiquidity, liqProof);
        euint64 dailyCap  = FHE.fromExternal(encDailyCap, dcProof);
        euint64 fee       = FHE.fromExternal(encFee, fProof);
        laneId = laneCount++;
        lanes[laneId] = BridgeLane({
            sourceChain: src, destChain: dst, tokenSymbol: token,
            liquidityReserveUSD: liquidity, totalVolumeBridged: FHE.asEuint64(0),
            dailyVolumeCap: dailyCap, todayVolume: FHE.asEuint64(0),
            feeBps: fee, totalFeesEarned: FHE.asEuint64(0),
            txCount: FHE.asEuint32(0), complianceScore: FHE.asEuint8(95),
            status: BridgeStatus.ACTIVE
        });
        FHE.allowThis(lanes[laneId].liquidityReserveUSD);
        FHE.allow(lanes[laneId].liquidityReserveUSD, msg.sender);
        FHE.allowThis(lanes[laneId].totalVolumeBridged);
        FHE.allowThis(lanes[laneId].dailyVolumeCap);
        FHE.allowThis(lanes[laneId].todayVolume);
        FHE.allowThis(lanes[laneId].feeBps);
        FHE.allowThis(lanes[laneId].totalFeesEarned);
        FHE.allowThis(lanes[laneId].txCount);
        FHE.allowThis(lanes[laneId].complianceScore);
        emit LaneCreated(laneId, src, dst);
    }

    function initiateBridge(
        uint256 laneId,
        address recipient,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant returns (uint256 txId) {
        require(lanes[laneId].status == BridgeStatus.ACTIVE, "Lane not active");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinCap = FHE.le(FHE.add(lanes[laneId].todayVolume, amount), lanes[laneId].dailyVolumeCap);
        euint64 fee = FHE.div(FHE.mul(amount, lanes[laneId].feeBps), 10000);
        euint64 received = FHE.sub(amount, fee);
        txId = txCount++;
        txs[txId] = BridgeTx({
            laneId: laneId, sender: msg.sender, recipient: recipient,
            amountUSD: amount, feeUSD: fee, receivedAmountUSD: received,
            initiatedAt: block.timestamp, completed: false, flagged: false
        });
        lanes[laneId].todayVolume = FHE.add(lanes[laneId].todayVolume, amount);
        lanes[laneId].totalVolumeBridged = FHE.add(lanes[laneId].totalVolumeBridged, amount);
        lanes[laneId].totalFeesEarned = FHE.add(lanes[laneId].totalFeesEarned, fee);
        lanes[laneId].txCount = FHE.add(lanes[laneId].txCount, FHE.asEuint32(1));
        _totalBridgeVolume = FHE.add(_totalBridgeVolume, amount);
        _totalBridgeFees = FHE.add(_totalBridgeFees, fee);
        FHE.allowThis(txs[txId].amountUSD);
        FHE.allow(txs[txId].amountUSD, msg.sender);
        FHE.allowThis(txs[txId].feeUSD);
        FHE.allow(txs[txId].feeUSD, msg.sender);
        FHE.allowThis(txs[txId].receivedAmountUSD);
        FHE.allow(txs[txId].receivedAmountUSD, recipient);
        FHE.allowThis(lanes[laneId].todayVolume);
        FHE.allowThis(lanes[laneId].totalVolumeBridged);
        FHE.allowThis(lanes[laneId].totalFeesEarned);
        FHE.allowThis(lanes[laneId].txCount);
        FHE.allowThis(_totalBridgeVolume);
        FHE.allowThis(_totalBridgeFees);
        emit BridgeTxInitiated(txId, laneId);
    }

    function completeTx(uint256 txId) external {
        require(isBridgeOperator[msg.sender], "Not operator");
        txs[txId].completed = true;
        emit BridgeTxCompleted(txId);
    }

    function flagTx(uint256 txId) external {
        require(isComplianceAgent[msg.sender], "Not compliance agent");
        txs[txId].flagged = true;
        _flaggedTxCount = FHE.add(_flaggedTxCount, FHE.asEuint32(1));
        FHE.allowThis(_flaggedTxCount);
        emit TxFlagged(txId);
    }

    function allowBridgeView(address viewer) external onlyOwner {
        FHE.allow(_totalBridgeVolume, viewer);
        FHE.allow(_totalBridgeFees, viewer);
        FHE.allow(_flaggedTxCount, viewer);
    }
}
