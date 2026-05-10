// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiEncryptedStructuredProduct
/// @notice Encrypted structured finance product (CLO/CDO-style).
///         Tranches have encrypted subordination levels, coupon rates,
///         and default thresholds. Principal allocation is confidential.
contract DeFiEncryptedStructuredProduct is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TrancheRating { AAA, AA, A, BBB, BB, B, Equity }
    enum ProductStatus { Structuring, Open, Active, Defaulted, Matured }

    struct Tranche {
        TrancheRating rating;
        euint64 principalUSD;         // encrypted tranche size
        euint32 couponRateBps;        // encrypted interest rate
        euint32 subordinationBps;     // encrypted credit support
        euint64 outstandingBalance;   // encrypted remaining balance
        euint32 defaultThresholdBps;  // encrypted default trigger
        euint64 collectedCoupons;     // encrypted coupons paid
        bool active;
    }

    struct InvestorPosition {
        uint256 trancheId;
        euint64 notionalUSD;       // encrypted investment size
        euint64 accruedCoupons;    // encrypted coupon earned
        euint64 principalReturned; // encrypted principal returned
        bool redeemed;
    }

    struct UnderlyingAsset {
        string assetId;
        euint64 faceValueUSD;      // encrypted asset face value
        euint32 creditRatingScore; // encrypted rating 0-1000
        euint32 probabilityOfDefaultBps; // encrypted PD
        bool defaulted;
    }

    mapping(uint256 => Tranche) private tranches;
    mapping(address => mapping(uint256 => InvestorPosition)) private positions;
    mapping(uint256 => UnderlyingAsset) private assets;
    mapping(address => bool) public isStructurer;
    mapping(address => bool) public isQualifiedInstitution;

    uint256 public trancheCount;
    uint256 public assetCount;
    ProductStatus public productStatus;

    euint64 private _totalCollateral;
    euint64 private _totalDefaultedAssets;
    euint32 private _weightedAvgCreditScore;

    event TrancheCreated(uint256 indexed id, TrancheRating rating);
    event AssetAdded(uint256 indexed assetId);
    event InvestorSubscribed(address indexed investor, uint256 trancheId);
    event CouponDistributed(uint256 indexed trancheId);
    event AssetDefaulted(uint256 indexed assetId);
    event ProductMatured();

    modifier onlyStructurer() {
        require(isStructurer[msg.sender] || msg.sender == owner(), "Not structurer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCollateral = FHE.asEuint64(0);
        _totalDefaultedAssets = FHE.asEuint64(0);
        _weightedAvgCreditScore = FHE.asEuint32(0);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalDefaultedAssets);
        FHE.allowThis(_weightedAvgCreditScore);
        productStatus = ProductStatus.Structuring;
        isStructurer[msg.sender] = true;
    }

    function addStructurer(address s) external onlyOwner { isStructurer[s] = true; }
    function qualifyInstitution(address inst) external onlyOwner { isQualifiedInstitution[inst] = true; }

    function createTranche(
        TrancheRating rating,
        externalEuint64 encPrincipal, bytes calldata princProof,
        externalEuint32 encCoupon, bytes calldata couponProof,
        externalEuint32 encSubord, bytes calldata subordProof,
        externalEuint32 encDefThresh, bytes calldata defProof
    ) external onlyStructurer returns (uint256 trancheId) {
        require(productStatus == ProductStatus.Structuring, "Not in structuring");

        euint64 principal = FHE.fromExternal(encPrincipal, princProof);
        euint32 coupon = FHE.fromExternal(encCoupon, couponProof);
        euint32 subord = FHE.fromExternal(encSubord, subordProof);
        euint32 defThresh = FHE.fromExternal(encDefThresh, defProof);

        trancheId = trancheCount++;
        Tranche storage t = tranches[trancheId];
        t.rating = rating;
        t.principalUSD = principal;
        t.couponRateBps = coupon;
        t.subordinationBps = subord;
        t.outstandingBalance = principal;
        t.defaultThresholdBps = defThresh;
        t.collectedCoupons = FHE.asEuint64(0);
        t.active = true;

        FHE.allowThis(t.principalUSD); FHE.allowThis(t.couponRateBps);
        FHE.allowThis(t.subordinationBps); FHE.allowThis(t.outstandingBalance);
        FHE.allowThis(t.defaultThresholdBps); FHE.allowThis(t.collectedCoupons);

        emit TrancheCreated(trancheId, rating);
    }

    function addCollateralAsset(
        string calldata assetId,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint32 encCreditScore, bytes calldata csProof,
        externalEuint32 encPD, bytes calldata pdProof
    ) external onlyStructurer {
        euint64 faceValue = FHE.fromExternal(encFaceValue, fvProof);
        euint32 creditScore = FHE.fromExternal(encCreditScore, csProof);
        euint32 pd = FHE.fromExternal(encPD, pdProof);

        uint256 assetId_ = assetCount++;
        assets[assetId_].assetId = assetId;
        assets[assetId_].faceValueUSD = faceValue;
        assets[assetId_].creditRatingScore = creditScore;
        assets[assetId_].probabilityOfDefaultBps = pd;
        assets[assetId_].defaulted = false;

        _totalCollateral = FHE.add(_totalCollateral, faceValue);
        _weightedAvgCreditScore = FHE.add(
            FHE.div(_weightedAvgCreditScore, 2),
            FHE.div(creditScore, 2)
        );

        FHE.allowThis(assets[assetId_].faceValueUSD);
        FHE.allowThis(assets[assetId_].creditRatingScore);
        FHE.allowThis(assets[assetId_].probabilityOfDefaultBps);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_weightedAvgCreditScore);

        emit AssetAdded(assetId_);
    }

    function subscribeToTranche(
        uint256 trancheId,
        externalEuint64 encNotional, bytes calldata proof
    ) external nonReentrant {
        require(isQualifiedInstitution[msg.sender], "Not qualified");
        require(productStatus == ProductStatus.Open, "Not open");
        Tranche storage t = tranches[trancheId];
        require(t.active, "Tranche inactive");

        euint64 notional = FHE.fromExternal(encNotional, proof);
        ebool fits = FHE.le(notional, t.outstandingBalance);
        euint64 actual = FHE.select(fits, notional, t.outstandingBalance);

        InvestorPosition storage pos = positions[msg.sender][trancheId];
        pos.trancheId = trancheId;
        pos.notionalUSD = FHE.add(pos.notionalUSD, actual);
        pos.accruedCoupons = FHE.asEuint64(0);
        pos.principalReturned = FHE.asEuint64(0);

        ebool _safeSub119 = FHE.ge(t.outstandingBalance, actual);
        t.outstandingBalance = FHE.select(_safeSub119, FHE.sub(t.outstandingBalance, actual), FHE.asEuint64(0));

        FHE.allowThis(pos.notionalUSD); FHE.allow(pos.notionalUSD, msg.sender);
        FHE.allowThis(pos.accruedCoupons); FHE.allow(pos.accruedCoupons, msg.sender);
        FHE.allowThis(pos.principalReturned); FHE.allow(pos.principalReturned, msg.sender);
        FHE.allowThis(t.outstandingBalance);

        emit InvestorSubscribed(msg.sender, trancheId);
    }

    function distributeCoupon(
        uint256 trancheId,
        address investor,
        externalEuint64 encCouponAmt, bytes calldata proof
    ) external onlyStructurer {
        euint64 couponAmt = FHE.fromExternal(encCouponAmt, proof);
        positions[investor][trancheId].accruedCoupons = FHE.add(
            positions[investor][trancheId].accruedCoupons, couponAmt
        );
        tranches[trancheId].collectedCoupons = FHE.add(tranches[trancheId].collectedCoupons, couponAmt);
        FHE.allowThis(positions[investor][trancheId].accruedCoupons);
        FHE.allow(positions[investor][trancheId].accruedCoupons, investor);
        FHE.allowThis(tranches[trancheId].collectedCoupons);
        emit CouponDistributed(trancheId);
    }

    function reportAssetDefault(uint256 assetId_) external onlyStructurer {
        require(!assets[assetId_].defaulted, "Already defaulted");
        assets[assetId_].defaulted = true;
        _totalDefaultedAssets = FHE.add(_totalDefaultedAssets, assets[assetId_].faceValueUSD);
        FHE.allowThis(_totalDefaultedAssets);
        emit AssetDefaulted(assetId_);
    }

    function openProduct() external onlyStructurer {
        require(productStatus == ProductStatus.Structuring, "Wrong status");
        productStatus = ProductStatus.Open;
    }

    function matureProduct() external onlyStructurer {
        productStatus = ProductStatus.Matured;
        emit ProductMatured();
    }

    function allowProductStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateral, viewer);
        FHE.allow(_totalDefaultedAssets, viewer);
        FHE.allow(_weightedAvgCreditScore, viewer);
    }

    function allowPositionView(uint256 trancheId, address viewer) external {
        InvestorPosition storage pos = positions[msg.sender][trancheId];
        FHE.allow(pos.notionalUSD, viewer);
        FHE.allow(pos.accruedCoupons, viewer);
        FHE.allow(pos.principalReturned, viewer);
    }
}
