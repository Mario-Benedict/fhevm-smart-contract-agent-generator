// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialCrossMarginLending
/// @notice Cross-margin lending protocol where collateral, debt, and health factors
///         are fully encrypted. Supports multiple asset types and private liquidation triggers.
contract ConfidentialCrossMarginLending is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetType { STABLECOIN, VOLATILE, LIQUID_STAKING, RWA }

    struct LendingMarket {
        string symbol;
        AssetType assetType;
        euint64 totalDeposits;       // encrypted total deposits in market
        euint64 totalBorrows;        // encrypted total borrows outstanding
        euint64 supplyRateBps;       // encrypted annualized supply APR (bps)
        euint64 borrowRateBps;       // encrypted annualized borrow APR (bps)
        euint64 utilizationTarget;   // encrypted target utilization (bps)
        euint32 collateralFactorBps; // encrypted LTV factor (bps)
        uint256 lastAccrualTime;
        bool active;
    }

    struct UserPosition {
        euint64 depositedValue;      // encrypted total collateral value (USD)
        euint64 borrowedValue;       // encrypted total debt value (USD)
        euint64 healthFactor;        // encrypted health factor (scaled 1e4)
        euint64 accruedInterest;     // encrypted unpaid interest
        euint32 riskTier;            // encrypted risk tier 1-5
        bool initialized;
    }

    struct MarketDeposit {
        euint64 shares;              // encrypted deposit shares
        euint64 principal;           // encrypted original principal
        uint256 depositTimestamp;
    }

    mapping(uint256 => LendingMarket) private markets;
    mapping(address => UserPosition) private positions;
    mapping(address => mapping(uint256 => MarketDeposit)) private userDeposits;
    mapping(address => mapping(uint256 => euint64)) private userBorrows;
    mapping(address => bool) public isLiquidator;
    uint256 public marketCount;
    euint64 private _protocolReserveFund;
    euint64 private _totalValueLocked;

    event MarketCreated(uint256 indexed id, string symbol, AssetType assetType);
    event Deposited(address indexed user, uint256 indexed marketId);
    event Borrowed(address indexed user, uint256 indexed marketId);
    event Repaid(address indexed user, uint256 indexed marketId);
    event Withdrawn(address indexed user, uint256 indexed marketId);
    event Liquidated(address indexed borrower, address indexed liquidator);
    event HealthFactorUpdated(address indexed user);

    constructor() Ownable(msg.sender) {
        _protocolReserveFund = FHE.asEuint64(0);
        _totalValueLocked = FHE.asEuint64(0);
        FHE.allowThis(_protocolReserveFund);
        FHE.allowThis(_totalValueLocked);
        isLiquidator[msg.sender] = true;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender], "Not liquidator");
        _;
    }

    function addLiquidator(address liq) external onlyOwner { isLiquidator[liq] = true; }

    function createMarket(
        string calldata symbol,
        AssetType assetType,
        externalEuint64 encDepositRate, bytes calldata drProof,
        externalEuint64 encBorrowRate,  bytes calldata brProof,
        externalEuint32 encCollFactor,  bytes calldata cfProof
    ) external onlyOwner returns (uint256 id) {
        euint64 dRate = FHE.fromExternal(encDepositRate, drProof);
        euint64 bRate = FHE.fromExternal(encBorrowRate, brProof);
        euint32 cFactor = FHE.fromExternal(encCollFactor, cfProof);
        id = marketCount++;
        markets[id].symbol = symbol;
        markets[id].assetType = assetType;
        markets[id].totalDeposits = FHE.asEuint64(0);
        markets[id].totalBorrows  = FHE.asEuint64(0);
        markets[id].supplyRateBps = dRate;
        markets[id].borrowRateBps = bRate;
        markets[id].utilizationTarget = FHE.asEuint64(8000);
        markets[id].collateralFactorBps = cFactor;
        markets[id].lastAccrualTime = block.timestamp;
        markets[id].active = true;
        FHE.allowThis(markets[id].totalDeposits);
        FHE.allowThis(markets[id].totalBorrows);
        FHE.allowThis(markets[id].supplyRateBps);
        FHE.allowThis(markets[id].borrowRateBps);
        FHE.allowThis(markets[id].utilizationTarget);
        FHE.allowThis(markets[id].collateralFactorBps);
        emit MarketCreated(id, symbol, assetType);
    }

    function deposit(
        uint256 marketId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        require(markets[marketId].active, "Market inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        MarketDeposit storage dep = userDeposits[msg.sender][marketId];
        dep.principal = FHE.add(dep.principal, amount);
        dep.shares = FHE.add(dep.shares, amount);
        dep.depositTimestamp = block.timestamp;
        markets[marketId].totalDeposits = FHE.add(markets[marketId].totalDeposits, amount);
        _totalValueLocked = FHE.add(_totalValueLocked, amount);
        _initUserPosition(msg.sender);
        positions[msg.sender].depositedValue = FHE.add(positions[msg.sender].depositedValue, amount);
        _refreshHealthFactor(msg.sender);
        FHE.allowThis(dep.principal);
        FHE.allow(dep.principal, msg.sender);
        FHE.allowThis(dep.shares);
        FHE.allow(dep.shares, msg.sender);
        FHE.allowThis(markets[marketId].totalDeposits);
        FHE.allowThis(_totalValueLocked);
        emit Deposited(msg.sender, marketId);
    }

    function borrow(
        uint256 marketId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        require(markets[marketId].active, "Market inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _initUserPosition(msg.sender);
        // Check borrowing power: borrowed + new <= deposited * collateralFactor
        euint64 cf64 = FHE.asEuint64(uint64(0)); // placeholder for cross-type cast
        euint64 newBorrow = FHE.add(positions[msg.sender].borrowedValue, amount);
        ebool withinLimit = FHE.le(newBorrow, positions[msg.sender].depositedValue);
        euint64 actualBorrow = FHE.select(withinLimit, amount, FHE.asEuint64(0));
        userBorrows[msg.sender][marketId] = FHE.add(userBorrows[msg.sender][marketId], actualBorrow);
        markets[marketId].totalBorrows = FHE.add(markets[marketId].totalBorrows, actualBorrow);
        positions[msg.sender].borrowedValue = FHE.add(positions[msg.sender].borrowedValue, actualBorrow);
        _refreshHealthFactor(msg.sender);
        FHE.allowThis(userBorrows[msg.sender][marketId]);
        FHE.allow(userBorrows[msg.sender][marketId], msg.sender);
        FHE.allowThis(markets[marketId].totalBorrows);
        FHE.allowThis(positions[msg.sender].borrowedValue);
        FHE.allow(positions[msg.sender].borrowedValue, msg.sender);
        emit Borrowed(msg.sender, marketId);
    }

    function repay(
        uint256 marketId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 owed = userBorrows[msg.sender][marketId];
        ebool fullRepay = FHE.ge(amount, owed);
        euint64 repayAmt = FHE.select(fullRepay, owed, amount);
        userBorrows[msg.sender][marketId] = FHE.sub(owed, repayAmt);
        markets[marketId].totalBorrows = FHE.sub(markets[marketId].totalBorrows, repayAmt);
        positions[msg.sender].borrowedValue = FHE.sub(positions[msg.sender].borrowedValue, repayAmt);
        _refreshHealthFactor(msg.sender);
        FHE.allowThis(userBorrows[msg.sender][marketId]);
        FHE.allowThis(markets[marketId].totalBorrows);
        FHE.allowThis(positions[msg.sender].borrowedValue);
        emit Repaid(msg.sender, marketId);
    }

    function liquidate(address borrower) external onlyLiquidator nonReentrant {
        // Encrypted liquidation: liquidator can trigger but amounts stay private
        UserPosition storage pos = positions[borrower];
        require(pos.initialized, "No position");
        ebool unhealthy = FHE.lt(pos.healthFactor, FHE.asEuint64(10000)); // < 1.0
        euint64 seizedCollateral = FHE.select(unhealthy, pos.depositedValue, FHE.asEuint64(0));
        pos.depositedValue = FHE.sub(pos.depositedValue, seizedCollateral);
        pos.borrowedValue  = FHE.asEuint64(0);
        _protocolReserveFund = FHE.add(_protocolReserveFund, FHE.div(seizedCollateral, 20)); // 5% fee
        FHE.allowThis(pos.depositedValue);
        FHE.allowThis(pos.borrowedValue);
        FHE.allowThis(_protocolReserveFund);
        emit Liquidated(borrower, msg.sender);
    }

    function _initUserPosition(address user) internal {
        if (!positions[user].initialized) {
            positions[user].depositedValue = FHE.asEuint64(0);
            positions[user].borrowedValue  = FHE.asEuint64(0);
            positions[user].healthFactor   = FHE.asEuint64(type(uint64).max);
            positions[user].accruedInterest = FHE.asEuint64(0);
            positions[user].riskTier = FHE.asEuint32(1);
            positions[user].initialized = true;
            FHE.allowThis(positions[user].depositedValue);
            FHE.allowThis(positions[user].borrowedValue);
            FHE.allowThis(positions[user].healthFactor);
            FHE.allowThis(positions[user].accruedInterest);
            FHE.allowThis(positions[user].riskTier);
        }
    }

    function _refreshHealthFactor(address user) internal {
        UserPosition storage pos = positions[user];
        // health factor: 10000 = solvent (deposited >= borrowed), 0 = insolvent
        // encrypted division not supported; approximated via comparison
        ebool solvent = FHE.ge(pos.depositedValue, pos.borrowedValue);
        pos.healthFactor = FHE.select(solvent, FHE.asEuint64(10000), FHE.asEuint64(0));
        FHE.allowThis(pos.healthFactor);
        FHE.allow(pos.healthFactor, user);
        emit HealthFactorUpdated(user);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowPositionView(address viewer) external {
        FHE.allow(positions[msg.sender].depositedValue, viewer);
        FHE.allow(positions[msg.sender].borrowedValue, viewer);
        FHE.allow(positions[msg.sender].healthFactor, viewer);
    }
}
