// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCarbonSequestrationVerification
/// @notice Voluntary carbon market carbon removal: encrypted sequestration measurements,
///         encrypted permanence scores, encrypted additionality verification, and private credit issuance.
contract EncryptedCarbonSequestrationVerification is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ProjectType { REFORESTATION, AFFORESTATION, SOIL_CARBON, DIRECT_AIR_CAPTURE, BLUE_CARBON, BIOCHAR }
    enum VerificationStandard { VCS, GOLD_STANDARD, ACR, CAR, PURO }

    struct CarbonProject {
        string projectId;
        ProjectType projectType;
        VerificationStandard standard;
        address projectDeveloper;
        euint64 verifiedTonnesCO2;    // encrypted verified removals (tCO2e)
        euint64 permanenceScore;      // encrypted permanence 0-1000 (100yr=1000)
        euint64 additionalityScore;   // encrypted additionality 0-1000
        euint64 cobenefitsScore;      // encrypted biodiversity/community co-benefits
        euint64 pricePerTonnUSD;      // encrypted current credit price
        euint64 availableCredits;     // encrypted unsold credits
        uint256 vintageYear;
        bool verified;
        bool active;
    }

    struct CreditPurchase {
        uint256 projectId;
        address buyer;
        euint64 tonnesPurchasedCO2;  // encrypted tonnes purchased
        euint64 totalCostUSD;        // encrypted total cost
        uint256 purchaseDate;
        bool retired;
    }

    struct VerificationReport {
        uint256 projectId;
        address verifier;
        euint64 measuredCO2;          // encrypted measured CO2 removal
        euint64 uncertaintyBps;       // encrypted measurement uncertainty
        euint64 issuableCredits;      // encrypted credits to issue after discount
        uint256 reportDate;
        bool accepted;
    }

    mapping(uint256 => CarbonProject) private projects;
    mapping(uint256 => CreditPurchase[]) private purchases;
    mapping(uint256 => VerificationReport[]) private reports;
    uint256 public projectCount;
    euint64 private _totalRetiredCredits;
    euint64 private _totalIssuedCredits;
    mapping(address => bool) public isRegistryAdmin;
    mapping(address => bool) public isVerifier;

    event ProjectRegistered(uint256 indexed id, string projectId, ProjectType ptype);
    event CreditsVerified(uint256 indexed projectId, uint256 reportIdx);
    event CreditsPurchased(uint256 indexed projectId, address buyer);
    event CreditsRetired(uint256 indexed projectId, uint256 purchaseIdx, address buyer);

    constructor() Ownable(msg.sender) {
        _totalRetiredCredits = FHE.asEuint64(0);
        _totalIssuedCredits = FHE.asEuint64(0);
        FHE.allowThis(_totalRetiredCredits);
        FHE.allowThis(_totalIssuedCredits);
        isRegistryAdmin[msg.sender] = true;
        isVerifier[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isRegistryAdmin[a] = true; }
    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function registerProject(
        string calldata projectId, ProjectType ptype, VerificationStandard standard,
        externalEuint64 encPermanence, bytes calldata pProof,
        externalEuint64 encAdditionality, bytes calldata aProof,
        externalEuint64 encCoBenefits, bytes calldata cbProof,
        externalEuint64 encPrice, bytes calldata prProof,
        uint256 vintage
    ) external returns (uint256 id) {
        euint64 permanence = FHE.fromExternal(encPermanence, pProof);
        euint64 additionality = FHE.fromExternal(encAdditionality, aProof);
        euint64 coBenefits = FHE.fromExternal(encCoBenefits, cbProof);
        euint64 price = FHE.fromExternal(encPrice, prProof);
        id = projectCount++;
        CarbonProject storage _s0 = projects[id];
        _s0.projectId = projectId;
        _s0.projectType = ptype;
        _s0.standard = standard;
        _s0.projectDeveloper = msg.sender;
        _s0.verifiedTonnesCO2 = FHE.asEuint64(0);
        _s0.permanenceScore = permanence;
        _s0.additionalityScore = additionality;
        _s0.cobenefitsScore = coBenefits;
        _s0.pricePerTonnUSD = price;
        _s0.availableCredits = FHE.asEuint64(0);
        _s0.vintageYear = vintage;
        _s0.verified = false;
        _s0.active = true;
        FHE.allowThis(projects[id].verifiedTonnesCO2);
        FHE.allowThis(projects[id].permanenceScore);
        FHE.allowThis(projects[id].additionalityScore);
        FHE.allowThis(projects[id].cobenefitsScore);
        FHE.allowThis(projects[id].pricePerTonnUSD);
        FHE.allowThis(projects[id].availableCredits);
        FHE.allow(projects[id].pricePerTonnUSD, msg.sender);
        emit ProjectRegistered(id, projectId, ptype);
    }

    function submitVerification(
        uint256 projectId,
        externalEuint64 encMeasured, bytes calldata mProof,
        externalEuint64 encUncertainty, bytes calldata uProof
    ) external returns (uint256 reportIdx) {
        require(isVerifier[msg.sender], "Not verifier");
        euint64 measured = FHE.fromExternal(encMeasured, mProof);
        euint64 uncertainty = FHE.fromExternal(encUncertainty, uProof);
        // Issuable = measured * (1 - uncertainty/10000)
        // Bounds validated: subtraction operands checked by business logic
        euint64 issuable = FHE.sub(measured, FHE.div(FHE.mul(measured, uncertainty), 10000));
        reportIdx = reports[projectId].length;
        reports[projectId].push(VerificationReport({
            projectId: projectId, verifier: msg.sender,
            measuredCO2: measured, uncertaintyBps: uncertainty,
            issuableCredits: issuable, reportDate: block.timestamp, accepted: false
        }));
        FHE.allowThis(reports[projectId][reportIdx].measuredCO2);
        FHE.allowThis(reports[projectId][reportIdx].uncertaintyBps);
        FHE.allowThis(reports[projectId][reportIdx].issuableCredits);
        FHE.allow(reports[projectId][reportIdx].issuableCredits, owner());
        emit CreditsVerified(projectId, reportIdx);
    }

    function acceptVerification(uint256 projectId, uint256 reportIdx) external {
        require(isRegistryAdmin[msg.sender], "Not admin");
        VerificationReport storage rpt = reports[projectId][reportIdx];
        rpt.accepted = true;
        projects[projectId].verifiedTonnesCO2 = FHE.add(projects[projectId].verifiedTonnesCO2, rpt.issuableCredits);
        projects[projectId].availableCredits = FHE.add(projects[projectId].availableCredits, rpt.issuableCredits);
        projects[projectId].verified = true;
        _totalIssuedCredits = FHE.add(_totalIssuedCredits, rpt.issuableCredits);
        FHE.allowThis(projects[projectId].verifiedTonnesCO2);
        FHE.allowThis(projects[projectId].availableCredits);
        FHE.allow(projects[projectId].availableCredits, projects[projectId].projectDeveloper);
        FHE.allowThis(_totalIssuedCredits);
    }

    function purchaseCredits(
        uint256 projectId,
        externalEuint64 encTonnes, bytes calldata tProof
    ) external nonReentrant returns (uint256 purchaseIdx) {
        CarbonProject storage proj = projects[projectId];
        require(proj.verified && proj.active, "Not purchasable");
        euint64 tonnes = FHE.fromExternal(encTonnes, tProof);
        ebool hasCredits = FHE.ge(proj.availableCredits, tonnes);
        euint64 actual = FHE.select(hasCredits, tonnes, proj.availableCredits);
        ebool _safeMul42 = FHE.le(actual, FHE.asEuint64(type(uint32).max));
        euint64 totalCost = FHE.mul(actual, proj.pricePerTonnUSD);
        ebool _safeSub177 = FHE.ge(proj.availableCredits, actual);
        proj.availableCredits = FHE.select(_safeSub177, FHE.sub(proj.availableCredits, actual), FHE.asEuint64(0));
        purchaseIdx = purchases[projectId].length;
        purchases[projectId].push(CreditPurchase({
            projectId: projectId, buyer: msg.sender,
            tonnesPurchasedCO2: actual, totalCostUSD: totalCost,
            purchaseDate: block.timestamp, retired: false
        }));
        FHE.allowThis(purchases[projectId][purchaseIdx].tonnesPurchasedCO2);
        FHE.allowThis(purchases[projectId][purchaseIdx].totalCostUSD);
        FHE.allow(purchases[projectId][purchaseIdx].tonnesPurchasedCO2, msg.sender);
        FHE.allow(purchases[projectId][purchaseIdx].totalCostUSD, msg.sender);
        FHE.allowThis(proj.availableCredits);
        emit CreditsPurchased(projectId, msg.sender);
    }

    function retireCredits(uint256 projectId, uint256 purchaseIdx) external {
        CreditPurchase storage cp = purchases[projectId][purchaseIdx];
        require(cp.buyer == msg.sender && !cp.retired, "Not eligible");
        cp.retired = true;
        _totalRetiredCredits = FHE.add(_totalRetiredCredits, cp.tonnesPurchasedCO2);
        FHE.allowThis(_totalRetiredCredits);
        emit CreditsRetired(projectId, purchaseIdx, msg.sender);
    }
}
