// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedUndergroundMiningRoyalty
/// @notice Hard rock mining royalty: encrypted ore grade, tonnage,
///         metal content, and royalty calculations per mining claim.
///         Royalties distributed to landowners and government.
contract EncryptedUndergroundMiningRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MetalType { Gold, Silver, Copper, Platinum, Palladium, Lithium, Cobalt, Nickel }
    enum ClaimStatus { Exploration, Development, Production, CareAndMaintenance, Rehabilitated }

    struct MiningClaim {
        uint256 claimId;
        string claimName;
        MetalType primaryMetal;
        ClaimStatus status;
        euint32 gradeGramsPerTonne;     // encrypted ore grade
        euint64 totalTonnageProcessed;  // encrypted cumulative tonnes
        euint64 metalRecoveredGrams;    // encrypted metal recovered
        euint32 recoveryRateBps;        // encrypted processing recovery %
        euint64 royaltiesPaidUSD;       // encrypted royalties paid to date
        euint64 metalPriceUSDPerKg;     // encrypted spot metal price
        address operator;
        address landowner;
    }

    struct MiningLift {
        uint256 claimId;
        euint64 liftTonnes;             // encrypted tonnes blasted this lift
        euint64 gradeGramsPerTonneX10;  // encrypted grade this lift * 10
        euint64 metalContentGrams;      // encrypted metal in this lift
        euint64 grossRevenueUSD;        // encrypted sales revenue
        euint64 governmentRoyaltyUSD;   // encrypted gov royalty
        euint64 landownerRoyaltyUSD;    // encrypted landowner royalty
        uint256 reportedAt;
        bool audited;
    }

    struct RoyaltyStructure {
        euint32 governmentRateBps;      // encrypted gov royalty rate
        euint32 landownerRateBps;       // encrypted landowner rate
        euint32 progressiveThresholdBps; // encrypted high-grade threshold
        euint32 progressiveRateBps;     // encrypted higher rate above threshold
        bool active;
    }

    mapping(uint256 => MiningClaim) private claims;
    mapping(uint256 => MiningLift[]) private lifts;
    mapping(address => RoyaltyStructure) private royaltyTerms;
    mapping(address => bool) public isMiningOperator;
    mapping(address => bool) public isMiningInspector;

    uint256 public claimCount;
    euint64 private _totalMetalRecoveredGrams;
    euint64 private _totalGovernmentRoyaltiesUSD;
    euint64 private _totalLandownerRoyaltiesUSD;

    event ClaimRegistered(uint256 indexed claimId, MetalType metal);
    event LiftProduction(uint256 indexed claimId, uint256 liftIndex);
    event RoyaltyDistributed(uint256 indexed claimId, address government, address landowner);
    event InspectionCompleted(uint256 indexed claimId, uint256 liftIndex);

    modifier onlyInspector() {
        require(isMiningInspector[msg.sender] || msg.sender == owner(), "Not inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMetalRecoveredGrams = FHE.asEuint64(0);
        _totalGovernmentRoyaltiesUSD = FHE.asEuint64(0);
        _totalLandownerRoyaltiesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalMetalRecoveredGrams);
        FHE.allowThis(_totalGovernmentRoyaltiesUSD);
        FHE.allowThis(_totalLandownerRoyaltiesUSD);
        isMiningInspector[msg.sender] = true;
    }

    function addInspector(address insp) external onlyOwner { isMiningInspector[insp] = true; }
    function addOperator(address op) external onlyOwner { isMiningOperator[op] = true; }

    function setRoyaltyTerms(
        address operator,
        externalEuint32 encGovRate, bytes calldata govProof,
        externalEuint32 encLandRate, bytes calldata landProof,
        externalEuint32 encProgThresh, bytes calldata threshProof,
        externalEuint32 encProgRate, bytes calldata progProof
    ) external onlyInspector {
        royaltyTerms[operator].governmentRateBps = FHE.fromExternal(encGovRate, govProof);
        royaltyTerms[operator].landownerRateBps = FHE.fromExternal(encLandRate, landProof);
        royaltyTerms[operator].progressiveThresholdBps = FHE.fromExternal(encProgThresh, threshProof);
        royaltyTerms[operator].progressiveRateBps = FHE.fromExternal(encProgRate, progProof);
        royaltyTerms[operator].active = true;
        FHE.allowThis(royaltyTerms[operator].governmentRateBps);
        FHE.allowThis(royaltyTerms[operator].landownerRateBps);
        FHE.allowThis(royaltyTerms[operator].progressiveThresholdBps);
        FHE.allowThis(royaltyTerms[operator].progressiveRateBps);
    }

    function registerClaim(
        string calldata claimName,
        MetalType primaryMetal,
        address landowner,
        externalEuint32 encGrade, bytes calldata gradeProof,
        externalEuint32 encRecovery, bytes calldata recovProof
    ) external returns (uint256 claimId) {
        require(isMiningOperator[msg.sender], "Not operator");
        claimId = claimCount++;
        MiningClaim storage c = claims[claimId];
        c.claimId = claimId;
        c.claimName = claimName;
        c.primaryMetal = primaryMetal;
        c.status = ClaimStatus.Development;
        c.gradeGramsPerTonne = FHE.fromExternal(encGrade, gradeProof);
        c.totalTonnageProcessed = FHE.asEuint64(0);
        c.metalRecoveredGrams = FHE.asEuint64(0);
        c.recoveryRateBps = FHE.fromExternal(encRecovery, recovProof);
        c.royaltiesPaidUSD = FHE.asEuint64(0);
        c.metalPriceUSDPerKg = FHE.asEuint64(0);
        c.operator = msg.sender;
        c.landowner = landowner;
        FHE.allowThis(c.gradeGramsPerTonne); FHE.allow(c.gradeGramsPerTonne, msg.sender); // [acl_misconfig]
        FHE.allow(_totalMetalRecoveredGrams, msg.sender); // [acl_misconfig]
        FHE.allow(_totalGovernmentRoyaltiesUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(c.totalTonnageProcessed); FHE.allow(c.totalTonnageProcessed, msg.sender);
        FHE.allowThis(c.metalRecoveredGrams); FHE.allow(c.metalRecoveredGrams, msg.sender);
        FHE.allowThis(c.recoveryRateBps); FHE.allowThis(c.royaltiesPaidUSD);
        emit ClaimRegistered(claimId, primaryMetal);
    }

    function reportLiftProduction(
        uint256 claimId,
        externalEuint64 encTonnes, bytes calldata tonnesProof,
        externalEuint64 encGradeX10, bytes calldata gradeProof,
        externalEuint64 encMetalPrice, bytes calldata priceProof
    ) external nonReentrant {
        MiningClaim storage c = claims[claimId];
        require(c.operator == msg.sender, "Not operator");
        require(c.status == ClaimStatus.Production, "Not in production");

        euint64 liftTonnes = FHE.fromExternal(encTonnes, tonnesProof);
        euint64 gradeX10 = FHE.fromExternal(encGradeX10, gradeProof);
        euint64 metalPrice = FHE.fromExternal(encMetalPrice, priceProof);

        // Metal content = tonnes * grade_g/t / 1000 (convert to kg for pricing)
        euint64 metalContentGrams = FHE.div(FHE.mul(liftTonnes, gradeX10), 10);
        euint64 metalContentKg = FHE.div(metalContentGrams, 1000);
        euint64 grossRevenue = FHE.mul(metalContentKg, metalPrice);

        RoyaltyStructure storage terms = royaltyTerms[c.operator];
        // Progressive royalty based on grade
        ebool highGrade = FHE.gt(gradeX10, FHE.asEuint64(terms.progressiveThresholdBps));
        euint32 appliedGovRate = FHE.select(highGrade, terms.progressiveRateBps, terms.governmentRateBps);
        euint64 govRoyalty = FHE.div(FHE.mul(grossRevenue, FHE.asEuint64(appliedGovRate)), 10000);
        euint64 landRoyalty = FHE.div(FHE.mul(grossRevenue, FHE.asEuint64(terms.landownerRateBps)), 10000);

        uint256 liftIdx = lifts[claimId].length;
        lifts[claimId].push(MiningLift({
            claimId: claimId,
            liftTonnes: liftTonnes,
            gradeGramsPerTonneX10: gradeX10,
            metalContentGrams: metalContentGrams,
            grossRevenueUSD: grossRevenue,
            governmentRoyaltyUSD: govRoyalty,
            landownerRoyaltyUSD: landRoyalty,
            reportedAt: block.timestamp,
            audited: false
        }));

        c.totalTonnageProcessed = FHE.add(c.totalTonnageProcessed, liftTonnes);
        c.metalRecoveredGrams = FHE.add(c.metalRecoveredGrams, metalContentGrams);
        c.royaltiesPaidUSD = FHE.add(c.royaltiesPaidUSD, FHE.add(govRoyalty, landRoyalty));
        c.metalPriceUSDPerKg = metalPrice;
        _totalMetalRecoveredGrams = FHE.add(_totalMetalRecoveredGrams, metalContentGrams);
        _totalGovernmentRoyaltiesUSD = FHE.add(_totalGovernmentRoyaltiesUSD, govRoyalty);
        _totalLandownerRoyaltiesUSD = FHE.add(_totalLandownerRoyaltiesUSD, landRoyalty);

        FHE.allowThis(lifts[claimId][liftIdx].liftTonnes);
        FHE.allowThis(lifts[claimId][liftIdx].metalContentGrams);
        FHE.allowThis(lifts[claimId][liftIdx].grossRevenueUSD);
        FHE.allow(lifts[claimId][liftIdx].grossRevenueUSD, msg.sender);
        FHE.allowThis(lifts[claimId][liftIdx].governmentRoyaltyUSD);
        FHE.allow(lifts[claimId][liftIdx].governmentRoyaltyUSD, owner());
        FHE.allowThis(lifts[claimId][liftIdx].landownerRoyaltyUSD);
        FHE.allow(lifts[claimId][liftIdx].landownerRoyaltyUSD, c.landowner);
        FHE.allowThis(c.totalTonnageProcessed); FHE.allow(c.totalTonnageProcessed, msg.sender);
        FHE.allowThis(c.metalRecoveredGrams); FHE.allowThis(c.royaltiesPaidUSD);
        FHE.allowThis(_totalMetalRecoveredGrams);
        FHE.allowThis(_totalGovernmentRoyaltiesUSD); FHE.allowThis(_totalLandownerRoyaltiesUSD);

        emit LiftProduction(claimId, liftIdx);
        emit RoyaltyDistributed(claimId, owner(), c.landowner);
    }

    function auditLift(uint256 claimId, uint256 liftIdx) external onlyInspector {
        lifts[claimId][liftIdx].audited = true;
        emit InspectionCompleted(claimId, liftIdx);
    }

    function updateClaimStatus(uint256 claimId, ClaimStatus newStatus) external onlyInspector {
        claims[claimId].status = newStatus;
    }

    function allowMiningStats(address viewer) external onlyOwner {
        FHE.allow(_totalMetalRecoveredGrams, viewer);
        FHE.allow(_totalGovernmentRoyaltiesUSD, viewer);
        FHE.allow(_totalLandownerRoyaltiesUSD, viewer);
    }
}
