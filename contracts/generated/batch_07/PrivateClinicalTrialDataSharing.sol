// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateClinicalTrialDataSharing
/// @notice Pharmaceutical companies share encrypted clinical trial data.
///         Patient enrollment counts, dosage efficacy scores, and adverse event rates
///         are encrypted. Data purchasers pay encrypted fees to access anonymized results.
contract PrivateClinicalTrialDataSharing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TrialPhase { PhaseI, PhaseII, PhaseIII, PhaseIV }
    enum DataStatus { Collecting, Locked, ForSale, Sold }

    struct ClinicalTrial {
        address sponsor;
        string protocolId;
        string drugName;
        TrialPhase phase;
        euint32 enrolledPatients;        // encrypted enrollment count
        euint32 efficacyScore;           // encrypted primary endpoint score
        euint16 adverseEventRateBps;     // encrypted AE rate in basis points
        euint64 dataPriceUSD;            // encrypted dataset asking price
        euint64 totalRevenueUSD;         // encrypted cumulative data sales
        DataStatus status;
        uint256 lockDate;
    }

    struct DataLicense {
        uint256 trialId;
        address licensee;
        euint64 paidAmountUSD;           // encrypted license fee paid
        euint32 accessScore;             // encrypted access tier
        uint256 issuedAt;
        uint256 expiresAt;
    }

    mapping(uint256 => ClinicalTrial) private trials;
    mapping(uint256 => DataLicense) private licenses;
    mapping(address => bool) public isApprovedSponsor;
    mapping(address => bool) public isRegulator;            // FDA/EMA access
    mapping(uint256 => mapping(address => bool)) private hasLicense;

    uint256 public trialCount;
    uint256 public licenseCount;
    euint64 private _totalDataMarketRevenue;

    event TrialRegistered(uint256 indexed id, string protocolId, TrialPhase phase);
    event TrialLocked(uint256 indexed id);
    event LicenseIssued(uint256 indexed licenseId, uint256 trialId, address licensee);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDataMarketRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalDataMarketRevenue);
        isRegulator[msg.sender] = true;
    }

    function addSponsor(address s) external onlyOwner { isApprovedSponsor[s] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerTrial(
        string calldata protocolId,
        string calldata drugName,
        TrialPhase phase,
        externalEuint32 encEnrolled, bytes calldata eProof,
        externalEuint64 encDataPrice, bytes calldata dProof
    ) external whenNotPaused returns (uint256 id) {
        require(isApprovedSponsor[msg.sender], "Not approved sponsor");
        euint32 enrolled = FHE.fromExternal(encEnrolled, eProof);
        euint64 price = FHE.fromExternal(encDataPrice, dProof);
        id = trialCount++;
        trials[id].sponsor = msg.sender;
        trials[id].protocolId = protocolId;
        trials[id].drugName = drugName;
        trials[id].phase = phase;
        trials[id].enrolledPatients = enrolled;
        trials[id].efficacyScore = FHE.asEuint32(0);
        trials[id].adverseEventRateBps = FHE.asEuint16(0);
        trials[id].dataPriceUSD = price;
        trials[id].totalRevenueUSD = FHE.asEuint64(0);
        trials[id].status = DataStatus.Collecting;
        trials[id].lockDate = 0;
        FHE.allowThis(trials[id].enrolledPatients);
        FHE.allow(trials[id].enrolledPatients, msg.sender);
        FHE.allowThis(trials[id].efficacyScore);
        FHE.allowThis(trials[id].adverseEventRateBps);
        FHE.allowThis(trials[id].dataPriceUSD);
        FHE.allow(trials[id].dataPriceUSD, msg.sender);
        FHE.allowThis(trials[id].totalRevenueUSD);
        emit TrialRegistered(id, protocolId, phase);
    }

    function updateResults(
        uint256 trialId,
        externalEuint32 encEfficacy, bytes calldata eProof,
        externalEuint16 encAERate, bytes calldata aeProof
    ) external {
        ClinicalTrial storage t = trials[trialId];
        require(t.sponsor == msg.sender && t.status == DataStatus.Collecting, "Cannot update");
        t.efficacyScore = FHE.fromExternal(encEfficacy, eProof);
        t.adverseEventRateBps = FHE.fromExternal(encAERate, aeProof);
        FHE.allowThis(t.efficacyScore);
        FHE.allow(t.efficacyScore, msg.sender);
        FHE.allowThis(t.adverseEventRateBps);
        FHE.allow(t.adverseEventRateBps, msg.sender);
    }

    function lockTrial(uint256 trialId) external {
        ClinicalTrial storage t = trials[trialId];
        require(t.sponsor == msg.sender || isRegulator[msg.sender], "Unauthorized");
        require(t.status == DataStatus.Collecting, "Already locked");
        t.status = DataStatus.ForSale;
        t.lockDate = block.timestamp;
        emit TrialLocked(trialId);
    }

    function purchaseLicense(
        uint256 trialId,
        uint256 accessDays
    ) external whenNotPaused nonReentrant returns (uint256 licenseId) {
        ClinicalTrial storage t = trials[trialId];
        require(t.status == DataStatus.ForSale, "Not for sale");
        require(!hasLicense[trialId][msg.sender], "Already licensed");
        licenseId = licenseCount++;
        licenses[licenseId] = DataLicense({
            trialId: trialId, licensee: msg.sender,
            paidAmountUSD: t.dataPriceUSD, accessScore: FHE.asEuint32(100),
            issuedAt: block.timestamp,
            expiresAt: block.timestamp + accessDays * 1 days
        });
        t.totalRevenueUSD = FHE.add(t.totalRevenueUSD, t.dataPriceUSD);
        _totalDataMarketRevenue = FHE.add(_totalDataMarketRevenue, t.dataPriceUSD);
        hasLicense[trialId][msg.sender] = true;
        FHE.allowThis(licenses[licenseId].paidAmountUSD);
        FHE.allow(licenses[licenseId].paidAmountUSD, msg.sender);
        FHE.allow(licenses[licenseId].paidAmountUSD, t.sponsor);
        FHE.allowThis(licenses[licenseId].accessScore);
        FHE.allow(licenses[licenseId].accessScore, msg.sender);
        FHE.allowThis(t.totalRevenueUSD);
        FHE.allowThis(_totalDataMarketRevenue);
        // Grant data access to licensee
        FHE.allow(t.efficacyScore, msg.sender);
        FHE.allow(t.adverseEventRateBps, msg.sender);
        FHE.allow(t.enrolledPatients, msg.sender);
        emit LicenseIssued(licenseId, trialId, msg.sender);
    }

    function regulatorAccess(uint256 trialId, address regulator) external onlyRegulator {
        ClinicalTrial storage t = trials[trialId];
        FHE.allow(t.enrolledPatients, regulator);
        FHE.allow(t.efficacyScore, regulator);
        FHE.allow(t.adverseEventRateBps, regulator);
        FHE.allow(t.totalRevenueUSD, regulator);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalDataMarketRevenue, viewer);
    }
}
