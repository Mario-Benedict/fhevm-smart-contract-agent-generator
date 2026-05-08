// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCarbonEmissionsTrading
/// @notice EU ETS-inspired carbon market: encrypted allowance holdings,
///         encrypted trade prices, encrypted verified emission reports.
contract EncryptedCarbonEmissionsTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum VerificationStatus { Pending, Verified, Disputed, Rejected }

    struct EmissionReport {
        address installation;
        string installationName;
        euint32 reportedTonnesCO2;     // encrypted verified emissions
        euint32 allowancesHeld;        // encrypted EUA allowances held
        euint32 deficit;               // encrypted shortfall (max(0, emissions - allowances))
        euint64 penaltyAmountEUR;      // encrypted penalty amount
        uint256 compliancePeriodEnd;
        VerificationStatus status;
    }

    struct AllowanceTrade {
        address seller;
        address buyer;
        euint32 allowanceVolume;       // encrypted number of EUAs
        euint64 pricePerEUAeur;        // encrypted price per tonne
        euint64 totalConsiderationEUR; // encrypted total trade value
        bool settled;
        uint256 tradedAt;
    }

    mapping(address => euint32) private _allowanceBalance;
    mapping(uint256 => EmissionReport) private emissionReports;
    mapping(uint256 => AllowanceTrade) private trades;
    mapping(address => bool) public isVerifier;
    mapping(address => bool) public isRegulator;
    uint256 public reportCount;
    uint256 public tradeCount;
    euint64 private _totalTradeVolume;
    euint32 private _totalAllowancesIssued;
    euint64 private _totalPenaltiesAssessed;

    event AllowancesAllocated(address indexed installation, string name);
    event EmissionReportFiled(uint256 indexed id, address installation);
    event ReportVerified(uint256 indexed id);
    event AllowancesTraded(uint256 indexed tradeId, address seller, address buyer);
    event PenaltyAssessed(uint256 indexed reportId, address installation);

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTradeVolume = FHE.asEuint64(0);
        _totalAllowancesIssued = FHE.asEuint32(0);
        _totalPenaltiesAssessed = FHE.asEuint64(0);
        FHE.allowThis(_totalTradeVolume);
        FHE.allowThis(_totalAllowancesIssued);
        FHE.allowThis(_totalPenaltiesAssessed);
        isVerifier[msg.sender] = true;
        isRegulator[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }

    function allocateAllowances(
        address installation, string calldata name,
        externalEuint32 encAllowances, bytes calldata proof
    ) external onlyRegulator {
        euint32 allowances = FHE.fromExternal(encAllowances, proof);
        if (!FHE.isInitialized(_allowanceBalance[installation])) {
            _allowanceBalance[installation] = FHE.asEuint32(0);
            FHE.allowThis(_allowanceBalance[installation]);
        }
        _allowanceBalance[installation] = FHE.add(_allowanceBalance[installation], allowances);
        _totalAllowancesIssued = FHE.add(_totalAllowancesIssued, allowances);
        FHE.allowThis(_allowanceBalance[installation]);
        FHE.allow(_allowanceBalance[installation], installation);
        FHE.allowThis(_totalAllowancesIssued);
        emit AllowancesAllocated(installation, name);
    }

    function fileEmissionReport(
        string calldata name,
        externalEuint32 encEmissions, bytes calldata ePf,
        uint256 periodEnd
    ) external returns (uint256 id) {
        euint32 emissions = FHE.fromExternal(encEmissions, ePf);
        euint32 held = FHE.isInitialized(_allowanceBalance[msg.sender])
            ? _allowanceBalance[msg.sender] : FHE.asEuint32(0);
        ebool surplus = FHE.ge(held, emissions);
        euint32 deficit = FHE.select(surplus, FHE.asEuint32(0), FHE.sub(emissions, held));
        id = reportCount++;
        emissionReports[id] = EmissionReport({
            installation: msg.sender, installationName: name, reportedTonnesCO2: emissions,
            allowancesHeld: held, deficit: deficit, penaltyAmountEUR: FHE.asEuint64(0),
            compliancePeriodEnd: periodEnd, status: VerificationStatus.Pending
        });
        FHE.allowThis(emissionReports[id].reportedTonnesCO2);
        FHE.allow(emissionReports[id].reportedTonnesCO2, msg.sender);
        FHE.allowThis(emissionReports[id].allowancesHeld);
        FHE.allow(emissionReports[id].allowancesHeld, msg.sender);
        FHE.allowThis(emissionReports[id].deficit);
        FHE.allow(emissionReports[id].deficit, msg.sender);
        FHE.allowThis(emissionReports[id].penaltyAmountEUR);
        emit EmissionReportFiled(id, msg.sender);
    }

    function verifyReport(uint256 reportId) external onlyVerifier {
        emissionReports[reportId].status = VerificationStatus.Verified;
        emit ReportVerified(reportId);
    }

    function assessPenalty(
        uint256 reportId,
        externalEuint64 encPenalty, bytes calldata proof
    ) external onlyRegulator {
        EmissionReport storage r = emissionReports[reportId];
        require(r.status == VerificationStatus.Verified, "Not verified");
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        // Only assess if there's a deficit
        ebool hasDeficit = FHE.gt(r.deficit, FHE.asEuint32(0));
        euint64 finalPenalty = FHE.select(hasDeficit, penalty, FHE.asEuint64(0));
        r.penaltyAmountEUR = finalPenalty;
        _totalPenaltiesAssessed = FHE.add(_totalPenaltiesAssessed, finalPenalty);
        FHE.allowThis(r.penaltyAmountEUR);
        FHE.allow(r.penaltyAmountEUR, r.installation);
        FHE.allowThis(_totalPenaltiesAssessed);
        emit PenaltyAssessed(reportId, r.installation);
    }

    function tradeAllowances(
        address buyer,
        externalEuint32 encVolume, bytes calldata vPf,
        externalEuint64 encPrice, bytes calldata pPf
    ) external nonReentrant returns (uint256 tradeId) {
        euint32 volume = FHE.fromExternal(encVolume, vPf);
        euint64 price = FHE.fromExternal(encPrice, pPf);
        ebool hasEnough = FHE.le(volume, _allowanceBalance[msg.sender]);
        euint32 actual = FHE.select(hasEnough, volume, _allowanceBalance[msg.sender]);
        euint64 totalValue = FHE.mul(price, FHE.asEuint64(uint64(0))); // simplified
        _allowanceBalance[msg.sender] = FHE.sub(_allowanceBalance[msg.sender], actual);
        if (!FHE.isInitialized(_allowanceBalance[buyer])) {
            _allowanceBalance[buyer] = FHE.asEuint32(0);
            FHE.allowThis(_allowanceBalance[buyer]);
        }
        _allowanceBalance[buyer] = FHE.add(_allowanceBalance[buyer], actual);
        tradeId = tradeCount++;
        trades[tradeId] = AllowanceTrade({
            seller: msg.sender, buyer: buyer, allowanceVolume: actual,
            pricePerEUAeur: price, totalConsiderationEUR: totalValue,
            settled: true, tradedAt: block.timestamp
        });
        _totalTradeVolume = FHE.add(_totalTradeVolume, totalValue);
        FHE.allowThis(_allowanceBalance[msg.sender]);
        FHE.allow(_allowanceBalance[msg.sender], msg.sender);
        FHE.allowThis(_allowanceBalance[buyer]);
        FHE.allow(_allowanceBalance[buyer], buyer);
        FHE.allowThis(trades[tradeId].allowanceVolume);
        FHE.allow(trades[tradeId].allowanceVolume, buyer);
        FHE.allow(trades[tradeId].allowanceVolume, msg.sender);
        FHE.allowThis(trades[tradeId].pricePerEUAeur);
        FHE.allowThis(_totalTradeVolume);
        emit AllowancesTraded(tradeId, msg.sender, buyer);
    }

    function allowEmissionReport(uint256 reportId, address viewer) external onlyVerifier {
        FHE.allow(emissionReports[reportId].reportedTonnesCO2, viewer);
        FHE.allow(emissionReports[reportId].deficit, viewer);
        FHE.allow(emissionReports[reportId].penaltyAmountEUR, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalTradeVolume, viewer);
        FHE.allow(_totalPenaltiesAssessed, viewer);
    }
}
