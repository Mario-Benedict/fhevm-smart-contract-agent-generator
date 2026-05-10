// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHighNetWorthEstatePlanning
/// @notice Encrypted estate planning and wealth transfer for HNWI.
///         Asset values, beneficiary allocations, and tax liability
///         are encrypted. Supports conditional trusts and dynasty planning.
contract PrivateHighNetWorthEstatePlanning is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AssetClass { RealProperty, PrivateEquity, PublicSecurities, LifeInsurance, TrustInterest, BusinessInterest, Crypto }
    enum TrustType { Revocable, Irrevocable, CreditShelter, MaritalDeduction, CharitableRemainder, DynastyTrust }
    enum BeneficiaryRelation { Spouse, Child, Grandchild, Charity, Foundation, Other }

    struct EstateAsset {
        uint256 assetId;
        AssetClass assetClass;
        euint64 currentFMVUSD;          // encrypted fair market value
        euint64 costBasisUSD;           // encrypted tax basis
        euint64 annualIncomeUSD;        // encrypted income generated
        euint32 illiquidityDiscountBps; // encrypted discount for illiquid assets
        euint32 growthRateBps;          // encrypted projected growth
        bool inTrust;
        address trustee;
    }

    struct TrustAccount {
        uint256 trustId;
        TrustType trustType;
        address trustee;
        euint64 totalAssetValueUSD;     // encrypted total trust assets
        euint64 taxExclusionUsedUSD;    // encrypted exclusion consumed
        euint32 distributionBps;        // encrypted current distribution rate
        euint64 protectedAmountUSD;     // encrypted creditor-protected amount
        bool active;
        uint256 establishedAt;
    }

    struct Beneficiary {
        BeneficiaryRelation relation;
        euint32 allocationBps;          // encrypted inheritance share
        euint64 conditionalThresholdUSD; // encrypted minimum estate value for inheritance
        euint64 estimatedInheritanceUSD; // encrypted projected inheritance
        bool conditionalOnSurvival;
        bool active;
    }

    mapping(uint256 => EstateAsset) private assets;
    mapping(uint256 => TrustAccount) private trusts;
    mapping(address => Beneficiary) private beneficiaries;
    mapping(address => bool) public isEstatePlanner;
    mapping(address => bool) public isTrustee;

    uint256 public assetCount;
    uint256 public trustCount;

    euint64 private _totalEstateValueUSD;
    euint64 private _totalTaxExposureUSD;
    euint64 private _totalTrustProtectedUSD;

    event AssetRegistered(uint256 indexed assetId, AssetClass assetClass);
    event TrustEstablished(uint256 indexed trustId, TrustType trustType);
    event BeneficiaryAdded(address indexed beneficiary, BeneficiaryRelation relation);
    event AssetTransferredToTrust(uint256 indexed assetId, uint256 indexed trustId);
    event DistributionExecuted(address indexed beneficiary);

    modifier onlyPlanner() {
        require(isEstatePlanner[msg.sender] || msg.sender == owner(), "Not estate planner");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEstateValueUSD = FHE.asEuint64(0);
        _totalTaxExposureUSD = FHE.asEuint64(0);
        _totalTrustProtectedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalEstateValueUSD);
        FHE.allowThis(_totalTaxExposureUSD);
        FHE.allowThis(_totalTrustProtectedUSD);
        isEstatePlanner[msg.sender] = true;
    }

    function addPlanner(address p) external onlyOwner { isEstatePlanner[p] = true; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }

    function registerAsset(
        AssetClass assetClass,
        externalEuint64 encFMV, bytes calldata fmvProof,
        externalEuint64 encBasis, bytes calldata basisProof,
        externalEuint64 encIncome, bytes calldata incProof,
        externalEuint32 encDiscount, bytes calldata discProof,
        externalEuint32 encGrowth, bytes calldata growthProof
    ) external onlyPlanner returns (uint256 assetId) {
        assetId = assetCount++;
        EstateAsset storage a = assets[assetId];
        a.assetId = assetId;
        a.assetClass = assetClass;
        a.currentFMVUSD = FHE.fromExternal(encFMV, fmvProof);
        a.costBasisUSD = FHE.fromExternal(encBasis, basisProof);
        a.annualIncomeUSD = FHE.fromExternal(encIncome, incProof);
        a.illiquidityDiscountBps = FHE.fromExternal(encDiscount, discProof);
        a.growthRateBps = FHE.fromExternal(encGrowth, growthProof);
        a.inTrust = false;

        // Apply illiquidity discount
        euint64 adjustedFMV = FHE.sub(a.currentFMVUSD, FHE.div(FHE.mul(a.currentFMVUSD, FHE.asEuint64(a.illiquidityDiscountBps)), 10000)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 taxableGain = FHE.sub(adjustedFMV, a.costBasisUSD);
        euint64 estimatedTax = FHE.div(FHE.mul(taxableGain, 2000), 10000); // 20% cap gains

        _totalEstateValueUSD = FHE.add(_totalEstateValueUSD, adjustedFMV);
        _totalTaxExposureUSD = FHE.add(_totalTaxExposureUSD, estimatedTax);

        FHE.allowThis(a.currentFMVUSD); FHE.allow(a.currentFMVUSD, owner());
        FHE.allowThis(a.costBasisUSD); FHE.allow(a.costBasisUSD, owner());
        FHE.allowThis(a.annualIncomeUSD);
        FHE.allowThis(a.illiquidityDiscountBps);
        FHE.allowThis(a.growthRateBps);
        FHE.allowThis(_totalEstateValueUSD); FHE.allowThis(_totalTaxExposureUSD);

        emit AssetRegistered(assetId, assetClass);
    }

    function establishTrust(
        TrustType trustType,
        address trustee,
        externalEuint32 encDistribBps, bytes calldata distProof
    ) external onlyPlanner returns (uint256 trustId) {
        require(isTrustee[trustee], "Not approved trustee");
        trustId = trustCount++;
        TrustAccount storage t = trusts[trustId];
        t.trustId = trustId;
        t.trustType = trustType;
        t.trustee = trustee;
        t.totalAssetValueUSD = FHE.asEuint64(0);
        t.taxExclusionUsedUSD = FHE.asEuint64(0);
        t.distributionBps = FHE.fromExternal(encDistribBps, distProof);
        t.protectedAmountUSD = FHE.asEuint64(0);
        t.active = true;
        t.establishedAt = block.timestamp;
        FHE.allowThis(t.totalAssetValueUSD); FHE.allow(t.totalAssetValueUSD, trustee);
        FHE.allowThis(t.taxExclusionUsedUSD);
        FHE.allowThis(t.distributionBps); FHE.allow(t.distributionBps, trustee);
        FHE.allowThis(t.protectedAmountUSD);
        emit TrustEstablished(trustId, trustType);
    }

    function addBeneficiary(
        address beneficiary,
        BeneficiaryRelation relation,
        externalEuint32 encAllocation, bytes calldata allocProof,
        externalEuint64 encThreshold, bytes calldata threshProof
    ) external onlyPlanner {
        euint32 allocation = FHE.fromExternal(encAllocation, allocProof);
        euint64 threshold = FHE.fromExternal(encThreshold, threshProof);
        Beneficiary storage b = beneficiaries[beneficiary];
        b.relation = relation;
        b.allocationBps = allocation;
        b.conditionalThresholdUSD = threshold;
        b.estimatedInheritanceUSD = FHE.div(FHE.mul(_totalEstateValueUSD, FHE.asEuint64(allocation)), 10000);
        b.conditionalOnSurvival = false;
        b.active = true;
        FHE.allowThis(b.allocationBps); FHE.allow(b.allocationBps, beneficiary);
        FHE.allowThis(b.conditionalThresholdUSD); FHE.allow(b.conditionalThresholdUSD, beneficiary);
        FHE.allowThis(b.estimatedInheritanceUSD); FHE.allow(b.estimatedInheritanceUSD, beneficiary);
        emit BeneficiaryAdded(beneficiary, relation);
    }

    function transferAssetToTrust(uint256 assetId, uint256 trustId) external onlyPlanner {
        require(!assets[assetId].inTrust, "Already in trust");
        require(trusts[trustId].active, "Trust not active");
        assets[assetId].inTrust = true;
        assets[assetId].trustee = trusts[trustId].trustee;
        trusts[trustId].totalAssetValueUSD = FHE.add(trusts[trustId].totalAssetValueUSD, assets[assetId].currentFMVUSD);
        trusts[trustId].protectedAmountUSD = FHE.add(trusts[trustId].protectedAmountUSD, assets[assetId].currentFMVUSD);
        _totalTrustProtectedUSD = FHE.add(_totalTrustProtectedUSD, assets[assetId].currentFMVUSD);
        FHE.allowThis(trusts[trustId].totalAssetValueUSD);
        FHE.allowThis(trusts[trustId].protectedAmountUSD);
        FHE.allowThis(_totalTrustProtectedUSD);
        emit AssetTransferredToTrust(assetId, trustId);
    }

    function executeDistribution(
        address beneficiary,
        externalEuint64 encDistribAmount, bytes calldata proof
    ) external onlyPlanner nonReentrant {
        Beneficiary storage b = beneficiaries[beneficiary];
        require(b.active, "Beneficiary not active");
        euint64 distrib = FHE.fromExternal(encDistribAmount, proof);
        ebool thresholdMet = FHE.ge(_totalEstateValueUSD, b.conditionalThresholdUSD);
        euint64 actualDistrib = FHE.select(thresholdMet, distrib, FHE.asEuint64(0));
        _totalEstateValueUSD = FHE.sub(_totalEstateValueUSD, actualDistrib);
        FHE.allowThis(_totalEstateValueUSD);
        FHE.allow(actualDistrib, beneficiary); // [acl_misconfig]
        FHE.allow(_totalEstateValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTaxExposureUSD, msg.sender); // [acl_misconfig]
        emit DistributionExecuted(beneficiary);
    }

    function allowEstateView(address viewer) external onlyPlanner {
        FHE.allow(_totalEstateValueUSD, viewer);
        FHE.allow(_totalTaxExposureUSD, viewer);
        FHE.allow(_totalTrustProtectedUSD, viewer);
    }
}
