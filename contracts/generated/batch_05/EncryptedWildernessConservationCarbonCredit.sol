// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWildernessConservationCarbonCredit
/// @notice Conservation finance: encrypted biodiversity credits, ecosystem service payments,
///         landowner compensation, and conservation covenant compliance scores.
contract EncryptedWildernessConservationCarbonCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EcosystemType { TROPICAL_FOREST, MANGROVE, WETLAND, GRASSLAND, CORAL_REEF, BOREAL_FOREST }
    enum ConservationStatus { ENDANGERED, THREATENED, VULNERABLE, STABLE, RECOVERING }

    struct ConservationArea {
        string areaName;
        string country;
        EcosystemType ecosystemType;
        address landowner;
        euint64 areaHectares;          // encrypted size
        euint64 carbonSequesteredTCO2; // encrypted annual carbon (tonnes)
        euint64 biodiversityScore;     // encrypted species richness metric
        euint64 annualPaymentUSD;      // encrypted landowner compensation
        euint64 totalPaymentsUSD;      // encrypted cumulative payments made
        euint32 speciesProtected;      // encrypted species count
        euint8  complianceScore;       // encrypted covenant compliance 0-100
        uint256 covenantStartDate;
        uint256 covenantEndDate;
        ConservationStatus status;
        bool verified;
    }

    struct BiodiversityCredit {
        uint256 areaId;
        euint64 creditsIssued;         // encrypted credit units
        euint64 pricePerCreditUSD;     // encrypted price
        euint64 creditsRetired;        // encrypted retired amount
        uint256 vintageYear;
        bool listed;
    }

    mapping(uint256 => ConservationArea) private areas;
    mapping(uint256 => BiodiversityCredit) private credits;
    mapping(address => bool) public isConservationAuthority;
    mapping(address => bool) public isBiodiversityAuditor;
    uint256 public areaCount;
    uint256 public creditCount;
    euint64 private _totalHectaresProtected;
    euint64 private _totalCarbonCreditsIssued;
    euint64 private _totalPaymentsToLandowners;

    event AreaRegistered(uint256 indexed areaId, EcosystemType eType);
    event CreditsIssued(uint256 indexed creditId, uint256 areaId);
    event LandownerPaid(uint256 indexed areaId);
    event ComplianceVerified(uint256 indexed areaId);

    constructor() Ownable(msg.sender) {
        _totalHectaresProtected = FHE.asEuint64(0);
        _totalCarbonCreditsIssued = FHE.asEuint64(0);
        _totalPaymentsToLandowners = FHE.asEuint64(0);
        FHE.allowThis(_totalHectaresProtected);
        FHE.allowThis(_totalCarbonCreditsIssued);
        FHE.allowThis(_totalPaymentsToLandowners);
        isConservationAuthority[msg.sender] = true;
        isBiodiversityAuditor[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isConservationAuthority[a] = true; }
    function addAuditor(address a) external onlyOwner { isBiodiversityAuditor[a] = true; }

    function registerConservationArea(
        string calldata name,
        string calldata country,
        EcosystemType eType,
        address landowner,
        externalEuint64 encHectares,   bytes calldata haProof,
        externalEuint64 encCarbon,     bytes calldata cProof,
        externalEuint64 encBiodiv,     bytes calldata bProof,
        externalEuint64 encPayment,    bytes calldata payProof,
        externalEuint32 encSpecies,    bytes calldata spProof,
        uint256 covenantYears
    ) external returns (uint256 areaId) {
        require(isConservationAuthority[msg.sender], "Not authority");
        euint64 hectares = FHE.fromExternal(encHectares, haProof);
        euint64 carbon   = FHE.fromExternal(encCarbon, cProof);
        euint64 biodiv   = FHE.fromExternal(encBiodiv, bProof);
        euint64 payment  = FHE.fromExternal(encPayment, payProof);
        euint32 species  = FHE.fromExternal(encSpecies, spProof);
        areaId = areaCount++;
        ConservationArea storage _s0 = areas[areaId];
        _s0.areaName = name;
        _s0.country = country;
        _s0.ecosystemType = eType;
        _s0.landowner = landowner;
        _s0.areaHectares = hectares;
        _s0.carbonSequesteredTCO2 = carbon;
        _s0.biodiversityScore = biodiv;
        _s0.annualPaymentUSD = payment;
        _s0.totalPaymentsUSD = FHE.asEuint64(0);
        _s0.speciesProtected = species;
        _s0.complianceScore = FHE.asEuint8(100);
        _s0.covenantStartDate = block.timestamp;
        _s0.covenantEndDate = block.timestamp + covenantYears * 365 days;
        _s0.status = ConservationStatus.STABLE;
        _s0.verified = false;
        _totalHectaresProtected = FHE.add(_totalHectaresProtected, hectares);
        FHE.allowThis(areas[areaId].areaHectares);
        FHE.allowThis(areas[areaId].carbonSequesteredTCO2);
        FHE.allowThis(areas[areaId].biodiversityScore);
        FHE.allowThis(areas[areaId].annualPaymentUSD);
        FHE.allow(areas[areaId].annualPaymentUSD, landowner);
        FHE.allowThis(areas[areaId].totalPaymentsUSD);
        FHE.allow(areas[areaId].totalPaymentsUSD, landowner);
        FHE.allowThis(areas[areaId].speciesProtected);
        FHE.allowThis(areas[areaId].complianceScore);
        FHE.allow(areas[areaId].complianceScore, landowner);
        FHE.allowThis(_totalHectaresProtected);
        emit AreaRegistered(areaId, eType);
    }

    function issueBiodiversityCredits(
        uint256 areaId,
        externalEuint64 encCredits, bytes calldata cProof,
        externalEuint64 encPrice,   bytes calldata pProof,
        uint256 vintageYear
    ) external returns (uint256 creditId) {
        require(isBiodiversityAuditor[msg.sender], "Not auditor");
        require(areas[areaId].verified, "Area not verified");
        euint64 _credits = FHE.fromExternal(encCredits, cProof);
        euint64 price   = FHE.fromExternal(encPrice, pProof);
        creditId = creditCount++;
        credits_[creditId] = BiodiversityCredit({
            areaId: areaId, creditsIssued: _credits, pricePerCreditUSD: price,
            creditsRetired: FHE.asEuint64(0), vintageYear: vintageYear, listed: true
        });
        _totalCarbonCreditsIssued = FHE.add(_totalCarbonCreditsIssued, _credits);
        FHE.allowThis(credits_[creditId].creditsIssued);
        FHE.allowThis(credits_[creditId].pricePerCreditUSD);
        FHE.allowThis(credits_[creditId].creditsRetired);
        FHE.allowThis(_totalCarbonCreditsIssued);
        emit CreditsIssued(creditId, areaId);
    }

    BiodiversityCredit[1000] private credits_;

    function payLandowner(uint256 areaId) external {
        require(isConservationAuthority[msg.sender], "Not authority");
        areas[areaId].totalPaymentsUSD = FHE.add(areas[areaId].totalPaymentsUSD, areas[areaId].annualPaymentUSD);
        _totalPaymentsToLandowners = FHE.add(_totalPaymentsToLandowners, areas[areaId].annualPaymentUSD);
        FHE.allowThis(areas[areaId].totalPaymentsUSD);
        FHE.allow(areas[areaId].totalPaymentsUSD, areas[areaId].landowner);
        FHE.allowThis(_totalPaymentsToLandowners);
        emit LandownerPaid(areaId);
    }

    function verifyCompliance(
        uint256 areaId,
        externalEuint8 encScore, bytes calldata proof
    ) external {
        require(isBiodiversityAuditor[msg.sender], "Not auditor");
        areas[areaId].complianceScore = FHE.fromExternal(encScore, proof);
        areas[areaId].verified = true;
        FHE.allowThis(areas[areaId].complianceScore);
        FHE.allow(areas[areaId].complianceScore, areas[areaId].landowner);
        emit ComplianceVerified(areaId);
    }

    function allowConservationStats(address viewer) external onlyOwner {
        FHE.allow(_totalHectaresProtected, viewer);
        FHE.allow(_totalCarbonCreditsIssued, viewer);
        FHE.allow(_totalPaymentsToLandowners, viewer);
    }
}
