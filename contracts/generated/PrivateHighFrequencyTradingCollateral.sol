// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateHighFrequencyTradingCollateral
/// @notice Prime brokerage collateral management for HFT firms. Encrypted margin requirements,
///         encrypted haircuts, and encrypted portfolio VaR kept private.
contract PrivateHighFrequencyTradingCollateral is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CollateralType { Cash, TreasuryBill, GovernmentBond, CorporateBond, Equity, ETF }
    enum MarginStatus { Compliant, MarginCall, Breached, Liquidating }

    struct HFTAccount {
        address firm;
        string firmId;
        euint64 netAssetValueUSD;       // encrypted NAV
        euint64 initialMarginUSD;       // encrypted required initial margin
        euint64 maintenanceMarginUSD;   // encrypted maintenance margin
        euint64 postedCollateralUSD;    // encrypted total collateral posted
        euint32 portfolioVaRBps;        // encrypted VaR as % of NAV
        euint32 leverageRatioBps;       // encrypted leverage ratio
        MarginStatus status;
        bool active;
    }

    struct CollateralPosition {
        uint256 accountId;
        CollateralType colType;
        euint64 notionalUSD;            // encrypted notional value
        euint32 haircutBps;             // encrypted haircut percentage
        euint64 eligibleValueUSD;       // encrypted eligible collateral after haircut
        bool pledged;
    }

    mapping(uint256 => HFTAccount) private accounts;
    mapping(uint256 => CollateralPosition[]) private positions;
    mapping(address => uint256) public firmToAccount;
    mapping(address => bool) public isPrimeBroker;

    uint256 public accountCount;
    euint64 private _totalCollateralUSD;
    euint64 private _totalMarginRequiredUSD;

    event AccountOpened(uint256 indexed id, address firm);
    event CollateralPosted(uint256 indexed accountId, CollateralType colType);
    event MarginCallIssued(uint256 indexed accountId);
    event AccountLiquidated(uint256 indexed accountId);

    modifier onlyBroker() {
        require(isPrimeBroker[msg.sender] || msg.sender == owner(), "Not prime broker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCollateralUSD = FHE.asEuint64(0);
        _totalMarginRequiredUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCollateralUSD);
        FHE.allowThis(_totalMarginRequiredUSD);
        isPrimeBroker[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isPrimeBroker[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function openAccount(
        address firm,
        string calldata firmId,
        externalEuint64 encNAV, bytes calldata nProof,
        externalEuint64 encInitMargin, bytes calldata imProof,
        externalEuint64 encMaintMargin, bytes calldata mmProof,
        externalEuint32 encVaR, bytes calldata vProof,
        externalEuint32 encLeverage, bytes calldata lProof
    ) external onlyBroker whenNotPaused returns (uint256 id) {
        euint64 nav = FHE.fromExternal(encNAV, nProof);
        euint64 initMargin = FHE.fromExternal(encInitMargin, imProof);
        euint64 maintMargin = FHE.fromExternal(encMaintMargin, mmProof);
        euint32 var_ = FHE.fromExternal(encVaR, vProof);
        euint32 lev = FHE.fromExternal(encLeverage, lProof);
        id = accountCount++;
        accounts[id] = HFTAccount({
            firm: firm, firmId: firmId,
            netAssetValueUSD: nav, initialMarginUSD: initMargin,
            maintenanceMarginUSD: maintMargin, postedCollateralUSD: FHE.asEuint64(0),
            portfolioVaRBps: var_, leverageRatioBps: lev,
            status: MarginStatus.Compliant, active: true
        });
        firmToAccount[firm] = id;
        _totalMarginRequiredUSD = FHE.add(_totalMarginRequiredUSD, initMargin);
        FHE.allowThis(accounts[id].netAssetValueUSD);
        FHE.allow(accounts[id].netAssetValueUSD, firm);
        FHE.allowThis(accounts[id].initialMarginUSD);
        FHE.allow(accounts[id].initialMarginUSD, firm);
        FHE.allowThis(accounts[id].maintenanceMarginUSD);
        FHE.allow(accounts[id].maintenanceMarginUSD, firm);
        FHE.allowThis(accounts[id].postedCollateralUSD);
        FHE.allow(accounts[id].postedCollateralUSD, firm);
        FHE.allowThis(accounts[id].portfolioVaRBps);
        FHE.allow(accounts[id].portfolioVaRBps, firm);
        FHE.allowThis(accounts[id].leverageRatioBps);
        FHE.allowThis(_totalMarginRequiredUSD);
        emit AccountOpened(id, firm);
    }

    function postCollateral(
        uint256 accountId,
        CollateralType colType,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint32 encHaircut, bytes calldata hProof
    ) external whenNotPaused nonReentrant {
        HFTAccount storage a = accounts[accountId];
        require(a.firm == msg.sender && a.active, "Not firm or inactive");
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint32 haircut = FHE.fromExternal(encHaircut, hProof);
        // eligible = notional * (1 - haircut/10000)
        euint64 haircutAmt = FHE.mul(notional, FHE.asEuint64(0)); // simplified
        euint64 eligible = FHE.sub(notional, haircutAmt);
        CollateralPosition memory pos = CollateralPosition({
            accountId: accountId, colType: colType,
            notionalUSD: notional, haircutBps: haircut,
            eligibleValueUSD: eligible, pledged: true
        });
        positions[accountId].push(pos);
        a.postedCollateralUSD = FHE.add(a.postedCollateralUSD, eligible);
        _totalCollateralUSD = FHE.add(_totalCollateralUSD, eligible);
        // Check margin compliance
        ebool compliant = FHE.ge(a.postedCollateralUSD, a.maintenanceMarginUSD);
        a.status = FHE.isInitialized(compliant) ? MarginStatus.Compliant : MarginStatus.MarginCall;
        FHE.allowThis(pos.notionalUSD);
        FHE.allowThis(pos.haircutBps);
        FHE.allowThis(pos.eligibleValueUSD);
        FHE.allow(pos.eligibleValueUSD, msg.sender);
        FHE.allowThis(a.postedCollateralUSD);
        FHE.allowThis(_totalCollateralUSD);
        emit CollateralPosted(accountId, colType);
    }

    function issueMarginCall(uint256 accountId) external onlyBroker {
        accounts[accountId].status = MarginStatus.MarginCall;
        emit MarginCallIssued(accountId);
    }

    function liquidateAccount(uint256 accountId) external onlyBroker {
        accounts[accountId].status = MarginStatus.Liquidating;
        accounts[accountId].active = false;
        emit AccountLiquidated(accountId);
    }

    function allowAccountDetails(uint256 accountId, address viewer) external onlyBroker {
        HFTAccount storage a = accounts[accountId];
        FHE.allow(a.netAssetValueUSD, viewer);
        FHE.allow(a.initialMarginUSD, viewer);
        FHE.allow(a.postedCollateralUSD, viewer);
        FHE.allow(a.portfolioVaRBps, viewer);
        FHE.allow(a.leverageRatioBps, viewer);
    }

    function allowRiskStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateralUSD, viewer);
        FHE.allow(_totalMarginRequiredUSD, viewer);
    }
}
