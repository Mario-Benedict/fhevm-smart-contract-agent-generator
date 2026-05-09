// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTimberForestCarbonProject
/// @notice Encrypted forestry carbon sequestration: hidden timber volume estimates,
///         confidential carbon credit issuances, private permanence buffer pool
///         contributions, and encrypted REDD+ benefit sharing allocations.
contract PrivateTimberForestCarbonProject is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ForestType { TropicalRainforest, TemperateForest, BorealForest, MangroveForest, AgroForestry }
    enum VerificationStandard { VCS, GoldStandard, ACR, CAR, Plan_Vivo }

    struct ForestProject {
        address projectDeveloper;
        address verifier;
        ForestType forestType;
        VerificationStandard standard;
        string projectRef;
        euint32 hectaresProtected;     // encrypted area
        euint64 annualSequestrationTCO2; // encrypted annual sequestration
        euint64 bufferPoolTCO2;        // encrypted permanence buffer
        euint64 issuedCreditsTCO2;     // encrypted issued credits
        euint64 creditPriceUSD;        // encrypted market price per tCO2
        euint16 leakageRateBps;        // encrypted leakage deduction
        bool verified;
    }

    struct BenefitSharingPayment {
        uint256 projectId;
        address community;
        euint64 shareAmountUSD;        // encrypted community share
        euint64 creditsAllocated;      // encrypted credits allocated
        uint256 paidAt;
    }

    mapping(uint256 => ForestProject) private projects;
    mapping(uint256 => BenefitSharingPayment) private benefitPayments;
    mapping(address => bool) public isCarbonVerifier;

    uint256 public projectCount;
    uint256 public paymentCount;
    euint64 private _totalCarbonIssuedTCO2;
    euint64 private _totalBenefitsPaidUSD;

    event ProjectRegistered(uint256 indexed id, ForestType forestType, VerificationStandard standard);
    event CreditsIssued(uint256 indexed projectId, uint256 issuedAt);
    event BenefitPaid(uint256 indexed paymentId, uint256 projectId);

    modifier onlyCarbonVerifier() {
        require(isCarbonVerifier[msg.sender] || msg.sender == owner(), "Not carbon verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCarbonIssuedTCO2 = FHE.asEuint64(0);
        _totalBenefitsPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCarbonIssuedTCO2);
        FHE.allowThis(_totalBenefitsPaidUSD);
        isCarbonVerifier[msg.sender] = true;
    }

    function addCarbonVerifier(address v) external onlyOwner { isCarbonVerifier[v] = true; }

    function registerProject(
        address verifier, ForestType forestType, VerificationStandard standard, string calldata projectRef,
        externalEuint32 encHectares, bytes calldata hProof,
        externalEuint64 encSequestration, bytes calldata sProof,
        externalEuint64 encCreditPrice, bytes calldata cpProof,
        externalEuint16 encLeakage, bytes calldata lProof
    ) external returns (uint256 id) {
        euint32 hectares = FHE.fromExternal(encHectares, hProof);
        euint64 sequestration = FHE.fromExternal(encSequestration, sProof);
        euint64 creditPrice = FHE.fromExternal(encCreditPrice, cpProof);
        euint16 leakage = FHE.fromExternal(encLeakage, lProof);
        id = projectCount++;
        ForestProject storage _s0 = projects[id];
        _s0.projectDeveloper = msg.sender;
        _s0.verifier = verifier;
        _s0.forestType = forestType;
        _s0.standard = standard;
        _s0.projectRef = projectRef;
        _s0.hectaresProtected = hectares;
        _s0.annualSequestrationTCO2 = sequestration;
        _s0.bufferPoolTCO2 = FHE.asEuint64(0);
        _s0.issuedCreditsTCO2 = FHE.asEuint64(0);
        _s0.creditPriceUSD = creditPrice;
        _s0.leakageRateBps = leakage;
        _s0.verified = false;
        FHE.allowThis(projects[id].hectaresProtected); FHE.allow(projects[id].hectaresProtected, msg.sender);
        FHE.allowThis(projects[id].annualSequestrationTCO2); FHE.allow(projects[id].annualSequestrationTCO2, msg.sender);
        FHE.allowThis(projects[id].bufferPoolTCO2); FHE.allow(projects[id].bufferPoolTCO2, verifier);
        FHE.allowThis(projects[id].issuedCreditsTCO2); FHE.allow(projects[id].issuedCreditsTCO2, msg.sender);
        FHE.allowThis(projects[id].creditPriceUSD); FHE.allow(projects[id].creditPriceUSD, msg.sender);
        FHE.allowThis(projects[id].leakageRateBps);
        emit ProjectRegistered(id, forestType, standard);
    }

    function issueCredits(
        uint256 projectId,
        externalEuint64 encCredits, bytes calldata cProof,
        externalEuint64 encBufferContrib, bytes calldata bcProof
    ) external onlyCarbonVerifier {
        ForestProject storage p = projects[projectId];
        euint64 credits = FHE.fromExternal(encCredits, cProof);
        euint64 bufferContrib = FHE.fromExternal(encBufferContrib, bcProof);
        p.issuedCreditsTCO2 = FHE.add(p.issuedCreditsTCO2, credits);
        p.bufferPoolTCO2 = FHE.add(p.bufferPoolTCO2, bufferContrib);
        p.verified = true;
        _totalCarbonIssuedTCO2 = FHE.add(_totalCarbonIssuedTCO2, credits);
        FHE.allowThis(p.issuedCreditsTCO2); FHE.allow(p.issuedCreditsTCO2, p.projectDeveloper);
        FHE.allowThis(p.bufferPoolTCO2); FHE.allow(p.bufferPoolTCO2, msg.sender);
        FHE.allowThis(_totalCarbonIssuedTCO2);
        emit CreditsIssued(projectId, block.timestamp);
    }

    function distributeBenefits(
        uint256 projectId, address community,
        externalEuint64 encShareAmt, bytes calldata saProof,
        externalEuint64 encCreditsAlloc, bytes calldata caProof
    ) external nonReentrant {
        ForestProject storage p = projects[projectId];
        require(msg.sender == p.projectDeveloper, "Not project developer");
        euint64 shareAmt = FHE.fromExternal(encShareAmt, saProof);
        euint64 creditsAlloc = FHE.fromExternal(encCreditsAlloc, caProof);
        uint256 pid = paymentCount++;
        benefitPayments[pid] = BenefitSharingPayment({
            projectId: projectId, community: community, shareAmountUSD: shareAmt,
            creditsAllocated: creditsAlloc, paidAt: block.timestamp
        });
        _totalBenefitsPaidUSD = FHE.add(_totalBenefitsPaidUSD, shareAmt);
        FHE.allowThis(benefitPayments[pid].shareAmountUSD); FHE.allow(benefitPayments[pid].shareAmountUSD, community); FHE.allow(benefitPayments[pid].shareAmountUSD, p.projectDeveloper);
        FHE.allowThis(benefitPayments[pid].creditsAllocated); FHE.allow(benefitPayments[pid].creditsAllocated, community);
        FHE.allowThis(_totalBenefitsPaidUSD);
        emit BenefitPaid(pid, projectId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalCarbonIssuedTCO2, viewer);
        FHE.allow(_totalBenefitsPaidUSD, viewer);
    }
}
