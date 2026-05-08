// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCrossChainBridgeLiquidity
/// @notice Cross-chain liquidity bridge: encrypted liquidity balances per chain, encrypted bridge fees,
///         encrypted slippage parameters, and private relayer bond management.
contract PrivateCrossChainBridgeLiquidity is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ChainPool {
        uint256 chainId;
        string chainName;
        euint64 liquidityUSD;        // encrypted pool liquidity
        euint64 dailyVolumeUSD;      // encrypted 24h volume
        euint64 utilizationRateBps;  // encrypted utilization
        euint64 bridgeFeeBps;        // encrypted bridge fee
        euint64 maxSlippageBps;      // encrypted max allowed slippage
        bool active;
    }

    struct LiquidityProvider {
        address lp;
        euint64 totalProvidedUSD;    // encrypted total liquidity provided
        euint64 earnedFeesUSD;       // encrypted earned fees
        euint64 withdrawalLockUSD;   // encrypted locked withdrawal amount
        uint256 lockExpiry;
        bool active;
    }

    struct Relayer {
        address relayer;
        euint64 bondAmountUSD;       // encrypted relayer bond
        euint64 slashableAmount;     // encrypted slashable portion
        euint64 successfulRelays;    // encrypted completed relay count
        euint64 failedRelays;        // encrypted failed relay count
        bool authorized;
    }

    struct BridgeTransaction {
        address user;
        uint256 sourceChain;
        uint256 destChain;
        euint64 amountUSD;           // encrypted transfer amount
        euint64 feeUSD;              // encrypted fee charged
        euint64 outputAmountUSD;     // encrypted received amount after slippage
        address relayer_;
        uint256 initiatedAt;
        bool completed;
        bool refunded;
    }

    mapping(uint256 => ChainPool) private pools;
    mapping(uint256 => mapping(address => LiquidityProvider)) private providers;
    mapping(address => Relayer) private relayers;
    mapping(uint256 => BridgeTransaction) private transactions;
    uint256 public txCount;
    euint64 private _totalTVL;
    euint64 private _totalFeesEarned;
    mapping(address => bool) public isBridgeAdmin;

    event PoolCreated(uint256 indexed chainId, string name);
    event LiquidityAdded(uint256 indexed chainId, address lp);
    event BridgeInitiated(uint256 indexed txId, uint256 srcChain, uint256 dstChain);
    event BridgeCompleted(uint256 indexed txId);
    event RelayerSlashed(address indexed relayer);

    constructor() Ownable(msg.sender) {
        _totalTVL = FHE.asEuint64(0);
        _totalFeesEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalTVL);
        FHE.allowThis(_totalFeesEarned);
        isBridgeAdmin[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isBridgeAdmin[a] = true; }

    function createPool(
        uint256 chainId, string calldata name,
        externalEuint64 encFee, bytes calldata fProof,
        externalEuint64 encMaxSlippage, bytes calldata msProof
    ) external {
        require(isBridgeAdmin[msg.sender], "Not admin");
        euint64 fee = FHE.fromExternal(encFee, fProof);
        euint64 maxSlippage = FHE.fromExternal(encMaxSlippage, msProof);
        pools[chainId] = ChainPool({
            chainId: chainId, chainName: name, liquidityUSD: FHE.asEuint64(0),
            dailyVolumeUSD: FHE.asEuint64(0), utilizationRateBps: FHE.asEuint64(0),
            bridgeFeeBps: fee, maxSlippageBps: maxSlippage, active: true
        });
        FHE.allowThis(pools[chainId].liquidityUSD);
        FHE.allowThis(pools[chainId].dailyVolumeUSD);
        FHE.allowThis(pools[chainId].utilizationRateBps);
        FHE.allowThis(pools[chainId].bridgeFeeBps);
        FHE.allowThis(pools[chainId].maxSlippageBps);
        emit PoolCreated(chainId, name);
    }

    function addLiquidity(
        uint256 chainId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(pools[chainId].active, "Pool inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        LiquidityProvider storage lp = providers[chainId][msg.sender];
        if (!FHE.isInitialized(lp.totalProvidedUSD)) {
            lp.totalProvidedUSD = FHE.asEuint64(0);
            lp.earnedFeesUSD = FHE.asEuint64(0);
            lp.withdrawalLockUSD = FHE.asEuint64(0);
            lp.lp = msg.sender;
            lp.active = true;
            FHE.allowThis(lp.totalProvidedUSD);
            FHE.allowThis(lp.earnedFeesUSD);
            FHE.allowThis(lp.withdrawalLockUSD);
        }
        lp.totalProvidedUSD = FHE.add(lp.totalProvidedUSD, amount);
        pools[chainId].liquidityUSD = FHE.add(pools[chainId].liquidityUSD, amount);
        _totalTVL = FHE.add(_totalTVL, amount);
        FHE.allowThis(lp.totalProvidedUSD);
        FHE.allow(lp.totalProvidedUSD, msg.sender);
        FHE.allowThis(pools[chainId].liquidityUSD);
        FHE.allowThis(_totalTVL);
        emit LiquidityAdded(chainId, msg.sender);
    }

    function authorizeRelayer(
        address relayer_,
        externalEuint64 encBond, bytes calldata proof
    ) external {
        require(isBridgeAdmin[msg.sender], "Not admin");
        euint64 bond = FHE.fromExternal(encBond, proof);
        relayers[relayer_] = Relayer({
            relayer: relayer_, bondAmountUSD: bond,
            slashableAmount: FHE.div(bond, FHE.asEuint64(2)),
            successfulRelays: FHE.asEuint64(0), failedRelays: FHE.asEuint64(0),
            authorized: true
        });
        FHE.allowThis(relayers[relayer_].bondAmountUSD);
        FHE.allowThis(relayers[relayer_].slashableAmount);
        FHE.allowThis(relayers[relayer_].successfulRelays);
        FHE.allowThis(relayers[relayer_].failedRelays);
    }

    function initiateBridge(
        uint256 srcChain, uint256 dstChain, address relayer_,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant returns (uint256 txId) {
        require(pools[srcChain].active && pools[dstChain].active, "Pool inactive");
        require(relayers[relayer_].authorized, "Relayer not authorized");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 fee = FHE.div(FHE.mul(amount, pools[srcChain].bridgeFeeBps), 10000);
        euint64 output = FHE.sub(amount, fee);
        txId = txCount++;
        transactions[txId] = BridgeTransaction({
            user: msg.sender, sourceChain: srcChain, destChain: dstChain,
            amountUSD: amount, feeUSD: fee, outputAmountUSD: output,
            relayer_: relayer_, initiatedAt: block.timestamp, completed: false, refunded: false
        });
        pools[srcChain].liquidityUSD = FHE.sub(pools[srcChain].liquidityUSD, amount);
        _totalFeesEarned = FHE.add(_totalFeesEarned, fee);
        FHE.allowThis(transactions[txId].amountUSD);
        FHE.allowThis(transactions[txId].feeUSD);
        FHE.allowThis(transactions[txId].outputAmountUSD);
        FHE.allow(transactions[txId].outputAmountUSD, msg.sender);
        FHE.allow(transactions[txId].feeUSD, relayer_);
        FHE.allowThis(pools[srcChain].liquidityUSD);
        FHE.allowThis(_totalFeesEarned);
        emit BridgeInitiated(txId, srcChain, dstChain);
    }

    function completeBridge(uint256 txId) external {
        require(relayers[msg.sender].authorized, "Not relayer");
        BridgeTransaction storage tx_ = transactions[txId];
        require(!tx_.completed && tx_.relayer_ == msg.sender, "Not authorized");
        tx_.completed = true;
        pools[tx_.destChain].liquidityUSD = FHE.add(pools[tx_.destChain].liquidityUSD, tx_.outputAmountUSD);
        relayers[msg.sender].successfulRelays = FHE.add(relayers[msg.sender].successfulRelays, FHE.asEuint64(1));
        FHE.allowThis(pools[tx_.destChain].liquidityUSD);
        FHE.allowThis(relayers[msg.sender].successfulRelays);
        emit BridgeCompleted(txId);
    }

    function slashRelayer(address relayer_, externalEuint64 encSlashAmount, bytes calldata proof) external {
        require(isBridgeAdmin[msg.sender], "Not admin");
        euint64 slashAmt = FHE.fromExternal(encSlashAmount, proof);
        Relayer storage r = relayers[relayer_];
        ebool canSlash = FHE.ge(r.slashableAmount, slashAmt);
        r.slashableAmount = FHE.select(canSlash, FHE.sub(r.slashableAmount, slashAmt), FHE.asEuint64(0));
        r.failedRelays = FHE.add(r.failedRelays, FHE.asEuint64(1));
        FHE.allowThis(r.slashableAmount);
        FHE.allowThis(r.failedRelays);
        emit RelayerSlashed(relayer_);
    }
}
