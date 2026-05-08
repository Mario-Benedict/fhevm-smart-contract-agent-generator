// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAgriculturalInputSubsidy
/// @notice Government encrypted subsidy distribution for farmers.
///         Fertilizer, seed, and irrigation subsidies are distributed
///         based on encrypted land holdings and crop types.
contract EncryptedAgriculturalInputSubsidy is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CropType { Rice, Wheat, Maize, Soybean, Cotton, Sugarcane, Vegetables, Fruits }
    enum FarmerTier { Marginal, SmallHolder, SemiMedium, Medium, Large }
    enum SubsidyType { Fertilizer, ImprovedSeed, Irrigation, PestControl, Equipment }

    struct FarmerRecord {
        address farmerAddr;
        string farmerIdHash;       // hashed national ID
        FarmerTier tier;
        euint32 landHoldingAcresX10; // encrypted land in acres * 10
        euint8 primaryCropType;    // encrypted primary crop
        euint64 annualSubsidyUSD;  // encrypted total subsidy received
        euint32 creditScoreBps;    // encrypted agri credit score
        bool enrolled;
        uint256 enrolledAt;
    }

    struct SubsidyAllocation {
        SubsidyType subsidyType;
        euint64 amountUSD;           // encrypted amount per farmer
        euint32 eligibleTierMask;    // encrypted tier eligibility bitfield
        euint64 totalBudgetUSD;      // encrypted program budget
        euint64 disbursedUSD;        // encrypted disbursed so far
        bool active;
        uint256 programStart;
        uint256 programEnd;
    }

    struct FarmerClaim {
        uint256 farmerId;
        uint256 subsidyId;
        euint64 claimedAmountUSD;  // encrypted claimed
        bool approved;
        bool disbursed;
        uint256 claimedAt;
    }

    mapping(uint256 => FarmerRecord) private farmers;
    mapping(address => uint256) public farmerIndex;
    mapping(uint256 => SubsidyAllocation) private subsidyPrograms;
    mapping(uint256 => FarmerClaim[]) private farmerClaims;
    mapping(address => bool) public isAgriculturalOfficer;

    uint256 public farmerCount;
    uint256 public subsidyProgramCount;

    euint64 private _totalSubsidiesDisbursed;
    euint64 private _totalFarmersEnrolled;
    euint64 private _totalBudgetAllocated;

    event FarmerEnrolled(uint256 indexed farmerId, FarmerTier tier);
    event SubsidyProgramCreated(uint256 indexed subsidyId, SubsidyType subsidyType);
    event ClaimSubmitted(uint256 indexed farmerId, uint256 subsidyId);
    event ClaimApproved(uint256 indexed farmerId, uint256 subsidyId);
    event SubsidyDisbursed(uint256 indexed farmerId, uint256 subsidyId);

    modifier onlyOfficer() {
        require(isAgriculturalOfficer[msg.sender] || msg.sender == owner(), "Not agricultural officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSubsidiesDisbursed = FHE.asEuint64(0);
        _totalFarmersEnrolled = FHE.asEuint64(0);
        _totalBudgetAllocated = FHE.asEuint64(0);
        FHE.allowThis(_totalSubsidiesDisbursed);
        FHE.allowThis(_totalFarmersEnrolled);
        FHE.allowThis(_totalBudgetAllocated);
        isAgriculturalOfficer[msg.sender] = true;
    }

    function addOfficer(address off) external onlyOwner { isAgriculturalOfficer[off] = true; }

    function enrollFarmer(
        address farmerAddr,
        string calldata farmerIdHash,
        FarmerTier tier,
        CropType primaryCrop,
        externalEuint32 encLandAcres, bytes calldata landProof,
        externalEuint32 encCreditScore, bytes calldata csProof
    ) external onlyOfficer returns (uint256 farmerId) {
        require(!farmers[farmerIndex[farmerAddr]].enrolled || farmerIndex[farmerAddr] == 0, "Already enrolled");
        farmerId = farmerCount++;
        farmerIndex[farmerAddr] = farmerId;
        FarmerRecord storage f = farmers[farmerId];
        f.farmerAddr = farmerAddr;
        f.farmerIdHash = farmerIdHash;
        f.tier = tier;
        f.landHoldingAcresX10 = FHE.fromExternal(encLandAcres, landProof);
        f.primaryCropType = FHE.asEuint8(uint8(primaryCrop));
        f.annualSubsidyUSD = FHE.asEuint64(0);
        f.creditScoreBps = FHE.fromExternal(encCreditScore, csProof);
        f.enrolled = true;
        f.enrolledAt = block.timestamp;
        _totalFarmersEnrolled = FHE.add(_totalFarmersEnrolled, FHE.asEuint64(1));
        FHE.allowThis(f.landHoldingAcresX10); FHE.allow(f.landHoldingAcresX10, farmerAddr);
        FHE.allowThis(f.primaryCropType);
        FHE.allowThis(f.annualSubsidyUSD); FHE.allow(f.annualSubsidyUSD, farmerAddr);
        FHE.allowThis(f.creditScoreBps); FHE.allow(f.creditScoreBps, farmerAddr);
        FHE.allowThis(_totalFarmersEnrolled);
        emit FarmerEnrolled(farmerId, tier);
    }

    function createSubsidyProgram(
        SubsidyType subsidyType,
        externalEuint64 encAmountPerFarmer, bytes calldata amtProof,
        externalEuint32 encEligibilityMask, bytes calldata maskProof,
        externalEuint64 encTotalBudget, bytes calldata budgetProof,
        uint256 programStart, uint256 programEnd
    ) external onlyOfficer returns (uint256 subsidyId) {
        subsidyId = subsidyProgramCount++;
        SubsidyAllocation storage s = subsidyPrograms[subsidyId];
        s.subsidyType = subsidyType;
        s.amountUSD = FHE.fromExternal(encAmountPerFarmer, amtProof);
        s.eligibleTierMask = FHE.fromExternal(encEligibilityMask, maskProof);
        s.totalBudgetUSD = FHE.fromExternal(encTotalBudget, budgetProof);
        s.disbursedUSD = FHE.asEuint64(0);
        s.active = true;
        s.programStart = programStart;
        s.programEnd = programEnd;
        _totalBudgetAllocated = FHE.add(_totalBudgetAllocated, s.totalBudgetUSD);
        FHE.allowThis(s.amountUSD); FHE.allowThis(s.eligibleTierMask);
        FHE.allowThis(s.totalBudgetUSD); FHE.allowThis(s.disbursedUSD);
        FHE.allowThis(_totalBudgetAllocated);
        emit SubsidyProgramCreated(subsidyId, subsidyType);
    }

    function submitClaim(uint256 subsidyId) external nonReentrant {
        uint256 farmerId = farmerIndex[msg.sender];
        FarmerRecord storage f = farmers[farmerId];
        require(f.enrolled && f.farmerAddr == msg.sender, "Not enrolled farmer");
        SubsidyAllocation storage s = subsidyPrograms[subsidyId];
        require(s.active && block.timestamp >= s.programStart && block.timestamp <= s.programEnd, "Program not active");

        // Tier eligibility check
        uint32 farmerTierBit = uint32(1) << uint32(f.tier);
        ebool eligible = FHE.gt(FHE.and(s.eligibleTierMask, FHE.asEuint32(farmerTierBit)), FHE.asEuint32(0));
        euint64 claimAmount = FHE.select(eligible, s.amountUSD, FHE.asEuint64(0));

        uint256 claimIdx = farmerClaims[farmerId].length;
        farmerClaims[farmerId].push(FarmerClaim({
            farmerId: farmerId,
            subsidyId: subsidyId,
            claimedAmountUSD: claimAmount,
            approved: false,
            disbursed: false,
            claimedAt: block.timestamp
        }));

        FHE.allowThis(farmerClaims[farmerId][claimIdx].claimedAmountUSD);
        FHE.allow(farmerClaims[farmerId][claimIdx].claimedAmountUSD, msg.sender);

        emit ClaimSubmitted(farmerId, subsidyId);
    }

    function approveClaim(uint256 farmerId, uint256 claimIdx) external onlyOfficer {
        farmerClaims[farmerId][claimIdx].approved = true;
        emit ClaimApproved(farmerId, farmerClaims[farmerId][claimIdx].subsidyId);
    }

    function disburseClaim(uint256 farmerId, uint256 claimIdx) external onlyOfficer nonReentrant {
        FarmerClaim storage claim = farmerClaims[farmerId][claimIdx];
        require(claim.approved && !claim.disbursed, "Not approved or already disbursed");
        claim.disbursed = true;
        SubsidyAllocation storage s = subsidyPrograms[claim.subsidyId];
        s.disbursedUSD = FHE.add(s.disbursedUSD, claim.claimedAmountUSD);
        farmers[farmerId].annualSubsidyUSD = FHE.add(farmers[farmerId].annualSubsidyUSD, claim.claimedAmountUSD);
        _totalSubsidiesDisbursed = FHE.add(_totalSubsidiesDisbursed, claim.claimedAmountUSD);
        FHE.allowThis(s.disbursedUSD);
        FHE.allowThis(farmers[farmerId].annualSubsidyUSD);
        FHE.allow(farmers[farmerId].annualSubsidyUSD, farmers[farmerId].farmerAddr);
        FHE.allowThis(_totalSubsidiesDisbursed);
        emit SubsidyDisbursed(farmerId, claim.subsidyId);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalSubsidiesDisbursed, viewer);
        FHE.allow(_totalFarmersEnrolled, viewer);
        FHE.allow(_totalBudgetAllocated, viewer);
    }
}
