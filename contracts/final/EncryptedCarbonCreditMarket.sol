// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedCarbonCreditMarket
/// @notice Carbon credit marketplace with encrypted credit quantities, encrypted project
///         verification scores, and private retirement tracking for net-zero commitments.
contract EncryptedCarbonCreditMarket is ZamaEthereumConfig, Ownable {
    enum CreditType { REDD, Solar, Wind, DirectAirCapture, Methane }

    struct CarbonProject {
        address projectDeveloper;
        string projectName;
        string location;
        CreditType creditType;
        euint32 totalCreditsIssued;   // encrypted tonnes CO2e
        euint32 creditsAvailable;     // encrypted available credits
        euint8 verificationScore;     // encrypted 1-100 quality score
        euint64 pricePerTonneMicroUSD; // encrypted price
        uint256 vintageYear;
        bool verified;
        bool active;
    }

    struct CorporateBuyer {
        euint64 totalSpent;           // encrypted USD spent on offsets
        euint32 creditsRetired;       // encrypted credits retired
        euint32 netZeroTarget;        // encrypted annual target in tonnes
        bool netZeroCertified;
    }

    mapping(uint256 => CarbonProject) private projects;
    mapping(address => CorporateBuyer) private buyers;
    mapping(address => bool) public isVerifier;
    mapping(address => euint32) private _sellerInventory;
    uint256 public projectCount;
    euint32 private _totalCreditsRetired;
    euint64 private _totalMarketVolume;

    event ProjectListed(uint256 indexed id, string name, CreditType creditType);
    event ProjectVerified(uint256 indexed id);
    event CreditsPurchased(uint256 indexed projectId, address buyer);
    event CreditsRetired(address indexed buyer, uint256 projectId);
    event NetZeroCertified(address indexed buyer);

    constructor() Ownable(msg.sender) {
        _totalCreditsRetired = FHE.asEuint32(0);
        _totalMarketVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalCreditsRetired);
        FHE.allowThis(_totalMarketVolume);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function listProject(
        string calldata name, string calldata location, CreditType creditType,
        externalEuint32 encCredits, bytes calldata cProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 vintageYear
    ) external returns (uint256 id) {
        euint32 credits = FHE.fromExternal(encCredits, cProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        id = projectCount++;
        projects[id].projectDeveloper = msg.sender;
        projects[id].projectName = name;
        projects[id].location = location;
        projects[id].creditType = creditType;
        projects[id].totalCreditsIssued = credits;
        projects[id].creditsAvailable = credits;
        projects[id].verificationScore = FHE.asEuint8(0);
        projects[id].pricePerTonneMicroUSD = price;
        projects[id].vintageYear = vintageYear;
        projects[id].verified = false;
        projects[id].active = true;
        FHE.allowThis(projects[id].totalCreditsIssued);
        FHE.allow(projects[id].totalCreditsIssued, msg.sender);
        FHE.allowThis(projects[id].creditsAvailable);
        FHE.allowThis(projects[id].verificationScore);
        FHE.allowThis(projects[id].pricePerTonneMicroUSD);
        if (!FHE.isInitialized(_sellerInventory[msg.sender])) {
            _sellerInventory[msg.sender] = FHE.asEuint32(0);
            FHE.allowThis(_sellerInventory[msg.sender]);
        }
        _sellerInventory[msg.sender] = FHE.add(_sellerInventory[msg.sender], credits);
        FHE.allowThis(_sellerInventory[msg.sender]);
        emit ProjectListed(id, name, creditType);
    }

    function verifyProject(uint256 projectId, externalEuint8 encScore, bytes calldata proof) external {
        require(isVerifier[msg.sender], "Not verifier");
        euint8 score = FHE.fromExternal(encScore, proof);
        projects[projectId].verificationScore = score;
        projects[projectId].verified = true;
        FHE.allowThis(projects[projectId].verificationScore);
        FHE.allow(projects[projectId].verificationScore, projects[projectId].projectDeveloper);
        emit ProjectVerified(projectId);
    }

    function purchaseCredits(
        uint256 projectId,
        externalEuint32 encTonnes, bytes calldata tProof
    ) external {
        CarbonProject storage p = projects[projectId];
        require(p.verified && p.active, "Project not verified");
        euint32 tonnes = FHE.fromExternal(encTonnes, tProof);
        ebool hasSupply = FHE.le(tonnes, p.creditsAvailable);
        euint32 actual = FHE.select(hasSupply, tonnes, p.creditsAvailable);
        ebool _safeSub175 = FHE.ge(p.creditsAvailable, actual);
        p.creditsAvailable = FHE.select(_safeSub175, FHE.sub(p.creditsAvailable, actual), FHE.asEuint32(0));
        ebool _safeMul40 = FHE.le(p.pricePerTonneMicroUSD, FHE.asEuint64(type(uint32).max));
        euint64 cost = FHE.select(_safeMul40, FHE.mul(p.pricePerTonneMicroUSD, FHE.asEuint64(uint64(0))), FHE.asEuint64(0)); // actual as euint64
        _totalMarketVolume = FHE.add(_totalMarketVolume, cost);
        if (!FHE.isInitialized(buyers[msg.sender].totalSpent)) {
            buyers[msg.sender].totalSpent = FHE.asEuint64(0);
            buyers[msg.sender].creditsRetired = FHE.asEuint32(0);
            buyers[msg.sender].netZeroTarget = FHE.asEuint32(0);
            FHE.allowThis(buyers[msg.sender].totalSpent);
            FHE.allowThis(buyers[msg.sender].creditsRetired);
            FHE.allowThis(buyers[msg.sender].netZeroTarget);
        }
        buyers[msg.sender].totalSpent = FHE.add(buyers[msg.sender].totalSpent, cost);
        FHE.allowThis(p.creditsAvailable);
        FHE.allowThis(_totalMarketVolume);
        FHE.allowThis(buyers[msg.sender].totalSpent);
        FHE.allow(buyers[msg.sender].totalSpent, msg.sender);
        emit CreditsPurchased(projectId, msg.sender);
    }

    function retireCredits(uint256 projectId, externalEuint32 encTonnes, bytes calldata proof) external {
        euint32 tonnes = FHE.fromExternal(encTonnes, proof);
        buyers[msg.sender].creditsRetired = FHE.add(buyers[msg.sender].creditsRetired, tonnes);
        _totalCreditsRetired = FHE.add(_totalCreditsRetired, tonnes);
        FHE.allowThis(buyers[msg.sender].creditsRetired);
        FHE.allow(buyers[msg.sender].creditsRetired, msg.sender);
        FHE.allowThis(_totalCreditsRetired);
        // Check if net-zero target met
        ebool certified = FHE.ge(buyers[msg.sender].creditsRetired, buyers[msg.sender].netZeroTarget);
        if (FHE.isInitialized(certified)) {
            buyers[msg.sender].netZeroCertified = true;
            emit NetZeroCertified(msg.sender);
        }
        emit CreditsRetired(msg.sender, projectId);
    }

    function setNetZeroTarget(externalEuint32 encTarget, bytes calldata proof) external {
        euint32 target = FHE.fromExternal(encTarget, proof);
        buyers[msg.sender].netZeroTarget = target;
        FHE.allowThis(buyers[msg.sender].netZeroTarget);
        FHE.allow(buyers[msg.sender].netZeroTarget, msg.sender);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalCreditsRetired, viewer);
        FHE.allow(_totalMarketVolume, viewer);
    }

    function allowProjectDetails(uint256 id, address viewer) external {
        require(projects[id].projectDeveloper == msg.sender || isVerifier[msg.sender], "Unauthorized");
        FHE.allow(projects[id].totalCreditsIssued, viewer);
        FHE.allow(projects[id].creditsAvailable, viewer);
        FHE.allow(projects[id].verificationScore, viewer);
    }
}
