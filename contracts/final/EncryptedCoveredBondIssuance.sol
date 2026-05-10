// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCoveredBondIssuance
/// @notice Covered bond issuance with encrypted collateral pool quality metrics,
///         over-collateralization ratios, cover pool asset replacement mechanics,
///         and confidential investor allocation in AAA-rated note tranches.
contract EncryptedCoveredBondIssuance is ZamaEthereumConfig, AccessControl, ReentrancyGuard {

    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");

    enum AssetClass { RESIDENTIAL_MORTGAGE, COMMERCIAL_MORTGAGE, PUBLIC_SECTOR, SHIP, AIRCRAFT }
    enum BondStatus { ISSUANCE_OPEN, ACTIVE, MATURED, REDEEMED, DEFAULTED }

    struct CoverPoolAsset {
        AssetClass assetClass;
        euint64 outstandingBalance;  // encrypted asset balance
        euint64 marketValue;         // encrypted current market value
        euint64 ltv;                 // encrypted loan-to-value (bps)
        euint64 weightedAvgCoupon;   // encrypted weighted average coupon
        euint32 remainingTermMonths; // encrypted remaining term
        bool eligible;
        bool active;
    }

    struct CoveredBondSeries {
        BondStatus status;
        euint64 issueSize;           // encrypted issuance volume
        euint64 couponRate;          // encrypted coupon in bps
        euint64 coverPoolValue;      // encrypted total cover pool value
        euint64 nominalCoverRatio;   // encrypted OC ratio (bps, e.g., 10800 = 108%)
        euint64 stressTestResult;    // encrypted stressed OC ratio
        euint64 totalRepaid;         // encrypted cumulative repaid
        uint256 maturityDate;
        uint256 nextCouponDate;
        bool hardBullet;             // hard bullet vs soft bullet
    }

    struct InvestorHolding {
        euint64 nominalAmount;       // encrypted holding nominal
        euint64 accruedInterest;     // encrypted accrued interest
        euint64 yieldToMaturity;     // encrypted YTM (bps)
        uint256 purchaseDate;
        bool active;
    }

    mapping(bytes32 => CoverPoolAsset) private coverAssets;
    mapping(bytes32 => CoveredBondSeries) private bondSeries;
    mapping(bytes32 => mapping(address => InvestorHolding)) private investorHoldings;
    mapping(bytes32 => address[]) private seriesInvestors;

    euint64 private _totalCoverPoolOutstanding;  // encrypted pool total
    euint64 private _totalBondsOutstanding;      // encrypted bonds total
    euint64 private _minimumOCRatioBps;          // encrypted min OC ratio

    event AssetAddedToCoverPool(bytes32 indexed assetId, AssetClass assetClass);
    event AssetRemovedFromCoverPool(bytes32 indexed assetId);
    event BondSeriesIssued(bytes32 indexed seriesId, uint256 maturityDate);
    event CouponPaid(bytes32 indexed seriesId, uint256 paymentDate);
    event OCRatioUpdated(bytes32 indexed seriesId);
    event SoftBulletExtended(bytes32 indexed seriesId);

    constructor(
        externalEuint64 encMinOCRatio, bytes memory ocrProof
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
        _minimumOCRatioBps = FHE.fromExternal(encMinOCRatio, ocrProof);
        _totalCoverPoolOutstanding = FHE.asEuint64(0);
        _totalBondsOutstanding = FHE.asEuint64(0);
        FHE.allowThis(_minimumOCRatioBps);
        FHE.allowThis(_totalCoverPoolOutstanding);
        FHE.allowThis(_totalBondsOutstanding);
    }

    function addCoverAsset(
        bytes32 assetId,
        AssetClass assetClass,
        externalEuint64 encBalance, bytes calldata balProof,
        externalEuint64 encMarketValue, bytes calldata mvProof,
        externalEuint64 encLTV, bytes calldata ltvProof,
        externalEuint64 encCoupon, bytes calldata cpnProof,
        externalEuint32 encTerm, bytes calldata termProof
    ) external onlyRole(ISSUER_ROLE) {
        euint64 balance = FHE.fromExternal(encBalance, balProof);
        euint64 marketValue = FHE.fromExternal(encMarketValue, mvProof);
        euint64 ltv = FHE.fromExternal(encLTV, ltvProof);
        euint64 coupon = FHE.fromExternal(encCoupon, cpnProof);
        euint32 term = FHE.fromExternal(encTerm, termProof);

        coverAssets[assetId] = CoverPoolAsset({
            assetClass: assetClass,
            outstandingBalance: balance,
            marketValue: marketValue,
            ltv: ltv,
            weightedAvgCoupon: coupon,
            remainingTermMonths: term,
            eligible: true,
            active: true
        });

        _totalCoverPoolOutstanding = FHE.add(_totalCoverPoolOutstanding, balance);

        FHE.allowThis(balance);
        FHE.allowThis(marketValue);
        FHE.allowThis(ltv);
        FHE.allowThis(coupon);
        FHE.allowThis(term);
        FHE.allowThis(_totalCoverPoolOutstanding);

        emit AssetAddedToCoverPool(assetId, assetClass);
    }

    function issueBondSeries(
        bytes32 seriesId,
        externalEuint64 encIssueSize, bytes calldata isProof,
        externalEuint64 encCouponRate, bytes calldata crProof,
        uint256 maturityDate,
        uint256 firstCouponDate,
        bool hardBullet
    ) external onlyRole(ISSUER_ROLE) {
        require(maturityDate > block.timestamp, "Invalid maturity");
        euint64 issueSize = FHE.fromExternal(encIssueSize, isProof);
        euint64 couponRate = FHE.fromExternal(encCouponRate, crProof);

        // OC ratio stored as cover pool value (encrypted divisor not supported)
        euint64 ocRatio = _totalCoverPoolOutstanding;

        bondSeries[seriesId].status = BondStatus.ACTIVE;
        bondSeries[seriesId].issueSize = issueSize;
        bondSeries[seriesId].couponRate = couponRate;
        bondSeries[seriesId].coverPoolValue = _totalCoverPoolOutstanding;
        bondSeries[seriesId].nominalCoverRatio = ocRatio;
        bondSeries[seriesId].stressTestResult = FHE.asEuint64(0);
        bondSeries[seriesId].totalRepaid = FHE.asEuint64(0);
        bondSeries[seriesId].maturityDate = maturityDate;
        bondSeries[seriesId].nextCouponDate = firstCouponDate;
        bondSeries[seriesId].hardBullet = hardBullet;

        _totalBondsOutstanding = FHE.add(_totalBondsOutstanding, issueSize);

        FHE.allowThis(issueSize);
        FHE.allowThis(couponRate);
        FHE.allowThis(ocRatio);
        FHE.allowThis(bondSeries[seriesId].stressTestResult);
        FHE.allowThis(bondSeries[seriesId].totalRepaid);
        FHE.allowThis(_totalBondsOutstanding);

        emit BondSeriesIssued(seriesId, maturityDate);
        emit OCRatioUpdated(seriesId);
    }

    function allocateToInvestor(
        bytes32 seriesId,
        address investor,
        externalEuint64 encNominal, bytes calldata nomProof,
        externalEuint64 encYTM, bytes calldata ytmProof
    ) external onlyRole(ISSUER_ROLE) {
        require(hasRole(INVESTOR_ROLE, investor), "Not registered investor");
        euint64 nominal = FHE.fromExternal(encNominal, nomProof);
        euint64 ytm = FHE.fromExternal(encYTM, ytmProof);

        investorHoldings[seriesId][investor] = InvestorHolding({
            nominalAmount: nominal,
            accruedInterest: FHE.asEuint64(0),
            yieldToMaturity: ytm,
            purchaseDate: block.timestamp,
            active: true
        });
        seriesInvestors[seriesId].push(investor);

        FHE.allowThis(nominal);
        FHE.allow(nominal, investor);
        FHE.allowThis(ytm);
        FHE.allow(ytm, investor);
        FHE.allowThis(investorHoldings[seriesId][investor].accruedInterest);
        FHE.allow(investorHoldings[seriesId][investor].accruedInterest, investor);
    }

    function payCoupon(bytes32 seriesId) external onlyRole(ISSUER_ROLE) {
        CoveredBondSeries storage series = bondSeries[seriesId];
        require(series.status == BondStatus.ACTIVE, "Not active");
        require(block.timestamp >= series.nextCouponDate, "Too early");

        address[] storage investors = seriesInvestors[seriesId];
        for (uint256 i = 0; i < investors.length; i++) {
            InvestorHolding storage holding = investorHoldings[seriesId][investors[i]];
            if (holding.active) {
                euint64 couponPayment = FHE.div(
                    ebool _safeMul46 = FHE.le(holding.nominalAmount, FHE.asEuint64(type(uint32).max));
                    FHE.mul(holding.nominalAmount, series.couponRate),
                    10000
                );
                holding.accruedInterest = FHE.add(holding.accruedInterest, couponPayment);
                FHE.allowThis(holding.accruedInterest);
                FHE.allow(holding.accruedInterest, investors[i]);
                FHE.allowTransient(couponPayment, investors[i]);
            }
        }
        series.nextCouponDate += 180 days; // semi-annual
        emit CouponPaid(seriesId, block.timestamp);
    }

    function updateStressTest(
        bytes32 seriesId,
        externalEuint64 encStressedOCRatio, bytes calldata strProof
    ) external onlyRole(MONITOR_ROLE) {
        euint64 stressedRatio = FHE.fromExternal(encStressedOCRatio, strProof);
        bondSeries[seriesId].stressTestResult = stressedRatio;
        FHE.allowThis(stressedRatio);
        emit OCRatioUpdated(seriesId);
    }

    function extendSoftBullet(bytes32 seriesId, uint256 newMaturityDate) external onlyRole(ISSUER_ROLE) {
        CoveredBondSeries storage series = bondSeries[seriesId];
        require(!series.hardBullet, "Hard bullet: cannot extend");
        require(block.timestamp >= series.maturityDate - 30 days, "Too early to extend");
        series.maturityDate = newMaturityDate;
        emit SoftBulletExtended(seriesId);
    }

    function allowSeriesDataView(bytes32 seriesId, address viewer) external onlyRole(ISSUER_ROLE) {
        CoveredBondSeries storage series = bondSeries[seriesId];
        FHE.allow(series.issueSize, viewer);
        FHE.allow(series.couponRate, viewer);
        FHE.allow(series.coverPoolValue, viewer);
        FHE.allow(series.nominalCoverRatio, viewer);
    }
}
