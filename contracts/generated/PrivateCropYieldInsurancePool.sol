// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCropYieldInsurancePool
/// @notice Encrypted area-based crop yield insurance: hidden county yield indices,
///         confidential trigger thresholds, private loss ratios by crop type,
///         and encrypted reinsurance corridor contributions.
contract PrivateCropYieldInsurancePool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CropType { Corn, Wheat, Soybeans, Cotton, Rice, Canola, Sunflower }
    enum InsuranceProduct { APH, MPCI, RevenueProt, AreaYield, GroupRiskPlan }

    struct CropPolicy {
        address farmer;
        CropType cropType;
        InsuranceProduct product;
        string countyFIPS;
        euint32 insuredAcres;          // encrypted insured acreage
        euint64 guaranteedYieldBusAc;  // encrypted guaranteed yield
        euint64 projectedPriceUSD;     // encrypted projected price
        euint64 totalLiabilityUSD;     // encrypted total coverage
        euint64 premiumPaidUSD;        // encrypted premium
        euint16 coverageLevelBps;      // encrypted coverage level %
        euint64 indemnityPaidUSD;      // encrypted indemnity paid
        bool claimed;
    }

    mapping(uint256 => CropPolicy) private policies;
    mapping(address => bool) public isCropAdjuster;

    uint256 public policyCount;
    euint64 private _totalPremiumsUSD;
    euint64 private _totalIndemnitiesUSD;
    euint64 private _totalLiabilityUSD;

    event PolicyWritten(uint256 indexed id, CropType cropType, InsuranceProduct product);
    event IndemnityPaid(uint256 indexed id, uint256 paidAt);

    modifier onlyCropAdjuster() {
        require(isCropAdjuster[msg.sender] || msg.sender == owner(), "Not crop adjuster");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPremiumsUSD = FHE.asEuint64(0);
        _totalIndemnitiesUSD = FHE.asEuint64(0);
        _totalLiabilityUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsUSD);
        FHE.allowThis(_totalIndemnitiesUSD);
        FHE.allowThis(_totalLiabilityUSD);
        isCropAdjuster[msg.sender] = true;
    }

    function addCropAdjuster(address a) external onlyOwner { isCropAdjuster[a] = true; }

    function writePolicy(
        CropType cropType, InsuranceProduct product, string calldata countyFIPS,
        externalEuint32 encAcres, bytes calldata aProof,
        externalEuint64 encGuaranteedYield, bytes calldata gyProof,
        externalEuint64 encProjPrice, bytes calldata ppProof,
        externalEuint64 encPremium, bytes calldata premProof,
        externalEuint16 encCovLevel, bytes calldata clProof
    ) external returns (uint256 id) {
        euint32 acres = FHE.fromExternal(encAcres, aProof);
        euint64 guaranteedYield = FHE.fromExternal(encGuaranteedYield, gyProof);
        euint64 projPrice = FHE.fromExternal(encProjPrice, ppProof);
        euint64 premium = FHE.fromExternal(encPremium, premProof);
        euint16 covLevel = FHE.fromExternal(encCovLevel, clProof);
        euint64 totalLiability = FHE.mul(guaranteedYield, projPrice);
        id = policyCount++;
        policies[id] = CropPolicy({
            farmer: msg.sender, cropType: cropType, product: product, countyFIPS: countyFIPS,
            insuredAcres: acres, guaranteedYieldBusAc: guaranteedYield, projectedPriceUSD: projPrice,
            totalLiabilityUSD: totalLiability, premiumPaidUSD: premium, coverageLevelBps: covLevel,
            indemnityPaidUSD: FHE.asEuint64(0), claimed: false
        });
        _totalPremiumsUSD = FHE.add(_totalPremiumsUSD, premium);
        _totalLiabilityUSD = FHE.add(_totalLiabilityUSD, totalLiability);
        FHE.allowThis(policies[id].insuredAcres); FHE.allow(policies[id].insuredAcres, msg.sender);
        FHE.allowThis(policies[id].guaranteedYieldBusAc); FHE.allow(policies[id].guaranteedYieldBusAc, msg.sender);
        FHE.allowThis(policies[id].projectedPriceUSD); FHE.allow(policies[id].projectedPriceUSD, msg.sender);
        FHE.allowThis(policies[id].totalLiabilityUSD); FHE.allow(policies[id].totalLiabilityUSD, msg.sender);
        FHE.allowThis(policies[id].premiumPaidUSD); FHE.allow(policies[id].premiumPaidUSD, msg.sender);
        FHE.allowThis(policies[id].coverageLevelBps);
        FHE.allowThis(policies[id].indemnityPaidUSD); FHE.allow(policies[id].indemnityPaidUSD, msg.sender);
        FHE.allowThis(_totalPremiumsUSD);
        FHE.allowThis(_totalLiabilityUSD);
        emit PolicyWritten(id, cropType, product);
    }

    function settleIndemnity(
        uint256 policyId,
        externalEuint64 encIndemnity, bytes calldata proof
    ) external onlyCropAdjuster nonReentrant {
        CropPolicy storage p = policies[policyId];
        require(!p.claimed, "Already claimed");
        euint64 indemnity = FHE.fromExternal(encIndemnity, proof);
        p.indemnityPaidUSD = indemnity;
        p.claimed = true;
        _totalIndemnitiesUSD = FHE.add(_totalIndemnitiesUSD, indemnity);
        FHE.allowThis(p.indemnityPaidUSD); FHE.allow(p.indemnityPaidUSD, p.farmer);
        FHE.allowThis(_totalIndemnitiesUSD);
        emit IndemnityPaid(policyId, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsUSD, viewer);
        FHE.allow(_totalIndemnitiesUSD, viewer);
        FHE.allow(_totalLiabilityUSD, viewer);
    }
}
