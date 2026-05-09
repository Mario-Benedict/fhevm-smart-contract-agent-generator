// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRealEstateInvestmentTrust
/// @notice On-chain REIT with encrypted property valuations, confidential dividend
///         distributions, and private portfolio rebalancing decisions.
///         Supports office, retail, industrial, and residential sub-sectors.
contract PrivateRealEstateInvestmentTrust is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum PropertySector { OFFICE, RETAIL, INDUSTRIAL, RESIDENTIAL, HOSPITALITY, MIXED_USE }

    struct Property {
        PropertySector sector;
        bytes32 propertyId;
        euint64 appraisedValueUSD;     // encrypted current appraised value
        euint64 annualRentIncomeUSD;   // encrypted annual rental income
        euint64 operatingExpenseUSD;   // encrypted annual operating expenses
        euint64 netOperatingIncomeUSD; // encrypted NOI
        euint64 capRateBps;            // encrypted capitalization rate
        euint64 mortgageBalanceUSD;    // encrypted outstanding mortgage
        euint64 ltvRatioBps;           // encrypted loan-to-value ratio
        euint64 occupancyRateBps;      // encrypted occupancy rate
        uint256 acquisitionDate;
        bool active;
        bool encumbered;
    }

    struct REITShare {
        euint64 sharesOutstanding;     // encrypted shares in circulation
        euint64 navPerShareUSD;        // encrypted NAV per share
        euint64 ffoPerShareUSD;        // encrypted Funds From Operations per share
        euint64 dividendYieldBps;      // encrypted dividend yield
        euint64 dividendPerShare;      // encrypted quarterly dividend per share
        euint64 cumulativeDividends;   // encrypted total dividends paid
        euint64 premiumToNAVBps;       // encrypted market price premium/discount to NAV
    }

    struct Investor {
        euint64 sharesHeld;
        euint64 totalDividendsReceived;
        euint64 unrealizedGainLoss;
        euint64 costBasis;
        uint256 lastDividendClaim;
        bool approved;
        bool restricted; // locked-up or accredited investor restriction
    }

    mapping(bytes32 => Property) private properties;
    mapping(address => Investor) private investors;
    bytes32[] private propertyIds;
    REITShare private reitShare;
    mapping(address => bool) public isREITManager;
    mapping(address => bool) public isAppraisalFirm;

    euint64 private _totalGrossAssetValue;
    euint64 private _totalDebtOutstanding;
    euint64 private _distributableFFO;
    euint64 private _quarterlyDividendPool;

    event PropertyAcquired(bytes32 indexed propertyId, PropertySector sector);
    event PropertyDisposed(bytes32 indexed propertyId);
    event AppraisalUpdated(bytes32 indexed propertyId);
    event DividendDeclared(uint256 timestamp);
    event DividendClaimed(address indexed investor);
    event SharesIssued(address indexed investor);
    event NAVUpdated(uint256 timestamp);

    constructor(
        externalEuint64 encInitialShares, bytes memory isProof,
        externalEuint64 encInitialNAV, bytes memory navProof
    ) Ownable(msg.sender) {
        reitShare.sharesOutstanding = FHE.fromExternal(encInitialShares, isProof);
        reitShare.navPerShareUSD = FHE.fromExternal(encInitialNAV, navProof);
        reitShare.ffoPerShareUSD = FHE.asEuint64(0);
        reitShare.dividendYieldBps = FHE.asEuint64(500); // 5% initial yield
        reitShare.dividendPerShare = FHE.asEuint64(0);
        reitShare.cumulativeDividends = FHE.asEuint64(0);
        reitShare.premiumToNAVBps = FHE.asEuint64(0);
        _totalGrossAssetValue = FHE.asEuint64(0);
        _totalDebtOutstanding = FHE.asEuint64(0);
        _distributableFFO = FHE.asEuint64(0);
        _quarterlyDividendPool = FHE.asEuint64(0);
        FHE.allowThis(reitShare.sharesOutstanding);
        FHE.allowThis(reitShare.navPerShareUSD);
        FHE.allowThis(reitShare.ffoPerShareUSD);
        FHE.allowThis(reitShare.dividendYieldBps);
        FHE.allowThis(reitShare.dividendPerShare);
        FHE.allowThis(reitShare.cumulativeDividends);
        FHE.allowThis(reitShare.premiumToNAVBps);
        FHE.allowThis(_totalGrossAssetValue);
        FHE.allowThis(_totalDebtOutstanding);
        FHE.allowThis(_distributableFFO);
        FHE.allowThis(_quarterlyDividendPool);
        isREITManager[msg.sender] = true;
        isAppraisalFirm[msg.sender] = true;
    }

    modifier onlyREITManager() { require(isREITManager[msg.sender], "Not REIT manager"); _; }
    modifier onlyAppraisalFirm() { require(isAppraisalFirm[msg.sender], "Not appraisal firm"); _; }

    function acquireProperty(
        bytes32 propertyId,
        PropertySector sector,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encRent, bytes calldata rProof,
        externalEuint64 encOpEx, bytes calldata oProof,
        externalEuint64 encMortgage, bytes calldata mProof,
        externalEuint64 encOccupancy, bytes calldata occProof
    ) external onlyREITManager {
        require(!properties[propertyId].active, "Already owned");
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint64 rent = FHE.fromExternal(encRent, rProof);
        euint64 opex = FHE.fromExternal(encOpEx, oProof);
        euint64 mortgage = FHE.fromExternal(encMortgage, mProof);
        euint64 occupancy = FHE.fromExternal(encOccupancy, occProof);
        euint64 noi = FHE.sub(rent, opex);
        euint64 capRate = FHE.div(FHE.mul(noi, 10000), value);
        euint64 ltv = FHE.div(FHE.mul(mortgage, 10000), value);
        Property storage p = properties[propertyId];
        p.sector = sector;
        p.propertyId = propertyId;
        p.appraisedValueUSD = value;
        p.annualRentIncomeUSD = rent;
        p.operatingExpenseUSD = opex;
        p.netOperatingIncomeUSD = noi;
        p.capRateBps = capRate;
        p.mortgageBalanceUSD = mortgage;
        p.ltvRatioBps = ltv;
        p.occupancyRateBps = occupancy;
        p.acquisitionDate = block.timestamp;
        p.active = true;
        propertyIds.push(propertyId);
        _totalGrossAssetValue = FHE.add(_totalGrossAssetValue, value);
        _totalDebtOutstanding = FHE.add(_totalDebtOutstanding, mortgage);
        _distributableFFO = FHE.add(_distributableFFO, noi);
        FHE.allowThis(p.appraisedValueUSD);
        FHE.allowThis(p.annualRentIncomeUSD);
        FHE.allowThis(p.netOperatingIncomeUSD);
        FHE.allowThis(p.capRateBps);
        FHE.allowThis(p.mortgageBalanceUSD);
        FHE.allowThis(p.ltvRatioBps);
        FHE.allowThis(p.occupancyRateBps);
        FHE.allowThis(_totalGrossAssetValue);
        FHE.allowThis(_totalDebtOutstanding);
        FHE.allowThis(_distributableFFO);
        emit PropertyAcquired(propertyId, sector);
    }

    function updateAppraisal(
        bytes32 propertyId,
        externalEuint64 encNewValue, bytes calldata nvProof,
        externalEuint64 encNewRent, bytes calldata nrProof,
        externalEuint64 encNewOccupancy, bytes calldata noProof
    ) external onlyAppraisalFirm {
        Property storage p = properties[propertyId];
        require(p.active, "Property not active");
        euint64 newValue = FHE.fromExternal(encNewValue, nvProof);
        euint64 newRent = FHE.fromExternal(encNewRent, nrProof);
        euint64 newOccupancy = FHE.fromExternal(encNewOccupancy, noProof);
        // Update total asset value
        _totalGrossAssetValue = FHE.add(FHE.sub(_totalGrossAssetValue, p.appraisedValueUSD), newValue);
        euint64 newNOI = FHE.sub(newRent, p.operatingExpenseUSD);
        _distributableFFO = FHE.add(FHE.sub(_distributableFFO, p.netOperatingIncomeUSD), newNOI);
        p.appraisedValueUSD = newValue;
        p.annualRentIncomeUSD = newRent;
        p.netOperatingIncomeUSD = newNOI;
        p.occupancyRateBps = newOccupancy;
        p.capRateBps = FHE.div(FHE.mul(newNOI, 10000), newValue);
        p.ltvRatioBps = FHE.div(FHE.mul(p.mortgageBalanceUSD, 10000), newValue);
        FHE.allowThis(p.appraisedValueUSD);
        FHE.allowThis(p.annualRentIncomeUSD);
        FHE.allowThis(p.netOperatingIncomeUSD);
        FHE.allowThis(p.capRateBps);
        FHE.allowThis(p.ltvRatioBps);
        FHE.allowThis(p.occupancyRateBps);
        FHE.allowThis(_totalGrossAssetValue);
        FHE.allowThis(_distributableFFO);
        emit AppraisalUpdated(propertyId);
    }

    function declareDividend(externalEuint64 encDividendPerShare, bytes calldata dpProof) external onlyREITManager {
        euint64 divPerShare = FHE.fromExternal(encDividendPerShare, dpProof);
        reitShare.dividendPerShare = divPerShare;
        _quarterlyDividendPool = FHE.mul(divPerShare, reitShare.sharesOutstanding);
        reitShare.cumulativeDividends = FHE.add(reitShare.cumulativeDividends, _quarterlyDividendPool);
        FHE.allowThis(reitShare.dividendPerShare);
        FHE.allowThis(_quarterlyDividendPool);
        FHE.allowThis(reitShare.cumulativeDividends);
        emit DividendDeclared(block.timestamp);
    }

    function claimDividend() external nonReentrant {
        Investor storage inv = investors[msg.sender];
        require(inv.approved, "Not eligible");
        uint256 lastClaim = inv.lastDividendClaim;
        require(block.timestamp > lastClaim + 90 days, "Already claimed this quarter");
        euint64 dividendAmount = FHE.mul(inv.sharesHeld, reitShare.dividendPerShare);
        inv.totalDividendsReceived = FHE.add(inv.totalDividendsReceived, dividendAmount);
        inv.lastDividendClaim = block.timestamp;
        FHE.allowThis(inv.totalDividendsReceived);
        FHE.allow(inv.totalDividendsReceived, msg.sender);
        FHE.allowTransient(dividendAmount, msg.sender);
        emit DividendClaimed(msg.sender);
    }

    function issueShares(
        address investor,
        externalEuint64 encShares, bytes calldata sProof,
        externalEuint64 encCostBasis, bytes calldata cbProof
    ) external onlyREITManager {
        require(investors[investor].approved, "Not approved");
        euint64 shares = FHE.fromExternal(encShares, sProof);
        euint64 costBasis = FHE.fromExternal(encCostBasis, cbProof);
        Investor storage inv = investors[investor];
        inv.sharesHeld = FHE.add(inv.sharesHeld, shares);
        inv.costBasis = FHE.add(inv.costBasis, costBasis);
        reitShare.sharesOutstanding = FHE.add(reitShare.sharesOutstanding, shares);
        FHE.allowThis(inv.sharesHeld);
        FHE.allow(inv.sharesHeld, investor);
        FHE.allowThis(inv.costBasis);
        FHE.allow(inv.costBasis, investor);
        FHE.allowThis(reitShare.sharesOutstanding);
        emit SharesIssued(investor);
    }

    function updateNAV(externalEuint64 encNAV, bytes calldata navProof) external onlyREITManager {
        reitShare.navPerShareUSD = FHE.fromExternal(encNAV, navProof);
        euint64 netAssets = FHE.sub(_totalGrossAssetValue, _totalDebtOutstanding);
        reitShare.ffoPerShareUSD = FHE.div(_distributableFFO, reitShare.sharesOutstanding);
        FHE.allowThis(reitShare.navPerShareUSD);
        FHE.allowThis(reitShare.ffoPerShareUSD);
        emit NAVUpdated(block.timestamp);
    }

    function approveInvestor(address inv) external onlyOwner { investors[inv].approved = true; investors[inv].totalDividendsReceived = FHE.asEuint64(0); investors[inv].sharesHeld = FHE.asEuint64(0); investors[inv].costBasis = FHE.asEuint64(0); FHE.allowThis(investors[inv].sharesHeld); FHE.allow(investors[inv].sharesHeld, inv); }
    function addREITManager(address rm) external onlyOwner { isREITManager[rm] = true; }
    function addAppraisalFirm(address af) external onlyOwner { isAppraisalFirm[af] = true; }
    function allowREITStats(address analyst) external onlyOwner {
        FHE.allow(_totalGrossAssetValue, analyst);
        FHE.allow(_totalDebtOutstanding, analyst);
        FHE.allow(reitShare.navPerShareUSD, analyst);
        FHE.allow(reitShare.ffoPerShareUSD, analyst);
    }
}
