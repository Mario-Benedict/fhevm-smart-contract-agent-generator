// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateGeothermalEnergyRoyaltyV2
/// @notice Encrypted geothermal energy royalty management: hidden steam field output metrics,
///         confidential royalty rates per MWh, private government revenue sharing, and
///         encrypted long-term power purchase agreement pricing.
contract PrivateGeothermalEnergyRoyaltyV2 is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FieldType { HighEnthalpy, LowEnthalpy, CoProduced, Petrothermal }

    struct GeothermalField {
        address developer;
        FieldType fieldType;
        string fieldRef;
        string country;
        euint32 installedCapacityMW;   // encrypted installed capacity
        euint64 annualOutputMWh;       // encrypted annual generation
        euint64 royaltyRatePerkWh;     // encrypted royalty rate per kWh (cents)
        euint64 govRevenueShareBps;    // encrypted government share bps
        euint64 totalRoyaltiesAccruedUSD;
        euint64 ppaRatePerMWhUSD;      // encrypted PPA rate
        bool active;
    }

    struct RoyaltyPeriod {
        uint256 fieldId;
        euint64 periodOutputMWh;
        euint64 royaltyDueUSD;
        euint64 govShareUSD;
        uint256 periodStart;
        uint256 periodEnd;
        bool paid;
    }

    mapping(uint256 => GeothermalField) private fields;
    mapping(uint256 => RoyaltyPeriod) private royaltyPeriods;
    mapping(address => bool) public isEnergyRegulator;

    uint256 public fieldCount;
    uint256 public royaltyPeriodCount;
    euint64 private _totalRoyaltiesUSD;
    euint64 private _totalGovRevenueUSD;

    event FieldRegistered(uint256 indexed id, FieldType fieldType, string country);
    event RoyaltyPeriodSettled(uint256 indexed periodId, uint256 fieldId);

    modifier onlyEnergyRegulator() {
        require(isEnergyRegulator[msg.sender] || msg.sender == owner(), "Not energy regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRoyaltiesUSD = FHE.asEuint64(0);
        _totalGovRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltiesUSD);
        FHE.allowThis(_totalGovRevenueUSD);
        isEnergyRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isEnergyRegulator[r] = true; }

    function registerField(
        FieldType fieldType, string calldata fieldRef, string calldata country,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encAnnualOutput, bytes calldata aoProof,
        externalEuint64 encRoyaltyRate, bytes calldata rrProof,
        externalEuint64 encGovShare, bytes calldata gsProof,
        externalEuint64 encPPARate, bytes calldata ppaProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 annOutput = FHE.fromExternal(encAnnualOutput, aoProof);
        euint64 royaltyRate = FHE.fromExternal(encRoyaltyRate, rrProof);
        euint64 govShare = FHE.fromExternal(encGovShare, gsProof);
        euint64 ppaRate = FHE.fromExternal(encPPARate, ppaProof);
        id = fieldCount++;
        fields[id].developer = msg.sender;
        fields[id].fieldType = fieldType;
        fields[id].fieldRef = fieldRef;
        fields[id].country = country;
        fields[id].installedCapacityMW = cap;
        fields[id].annualOutputMWh = annOutput;
        fields[id].royaltyRatePerkWh = royaltyRate;
        fields[id].govRevenueShareBps = govShare;
        fields[id].totalRoyaltiesAccruedUSD = FHE.asEuint64(0);
        fields[id].ppaRatePerMWhUSD = ppaRate;
        fields[id].active = true;
        FHE.allowThis(fields[id].installedCapacityMW); FHE.allow(fields[id].installedCapacityMW, msg.sender);
        FHE.allowThis(fields[id].annualOutputMWh); FHE.allow(fields[id].annualOutputMWh, msg.sender);
        FHE.allowThis(fields[id].royaltyRatePerkWh); FHE.allow(fields[id].royaltyRatePerkWh, msg.sender);
        FHE.allowThis(fields[id].govRevenueShareBps);
        FHE.allowThis(fields[id].totalRoyaltiesAccruedUSD); FHE.allow(fields[id].totalRoyaltiesAccruedUSD, msg.sender);
        FHE.allowThis(fields[id].ppaRatePerMWhUSD); FHE.allow(fields[id].ppaRatePerMWhUSD, msg.sender);
        emit FieldRegistered(id, fieldType, country);
    }

    function settleRoyaltyPeriod(
        uint256 fieldId, externalEuint64 encPeriodOutput, bytes calldata poProof,
        uint256 periodStart, uint256 periodEnd
    ) external onlyEnergyRegulator nonReentrant returns (uint256 periodId) {
        GeothermalField storage f = fields[fieldId];
        require(f.active, "Field not active");
        euint64 periodOutput = FHE.fromExternal(encPeriodOutput, poProof);
        euint64 royaltyDue = FHE.mul(periodOutput, f.royaltyRatePerkWh);
        euint64 govSharePortion = FHE.div(royaltyDue, 4); // 25% gov share (plaintext divisor)
        periodId = royaltyPeriodCount++;
        royaltyPeriods[periodId] = RoyaltyPeriod({
            fieldId: fieldId, periodOutputMWh: periodOutput, royaltyDueUSD: royaltyDue,
            govShareUSD: govSharePortion, periodStart: periodStart, periodEnd: periodEnd, paid: false
        });
        f.totalRoyaltiesAccruedUSD = FHE.add(f.totalRoyaltiesAccruedUSD, royaltyDue);
        _totalRoyaltiesUSD = FHE.add(_totalRoyaltiesUSD, royaltyDue);
        _totalGovRevenueUSD = FHE.add(_totalGovRevenueUSD, govSharePortion);
        FHE.allowThis(royaltyPeriods[periodId].periodOutputMWh); FHE.allow(royaltyPeriods[periodId].periodOutputMWh, f.developer);
        FHE.allowThis(royaltyPeriods[periodId].royaltyDueUSD); FHE.allow(royaltyPeriods[periodId].royaltyDueUSD, f.developer);
        FHE.allowThis(royaltyPeriods[periodId].govShareUSD);
        FHE.allowThis(f.totalRoyaltiesAccruedUSD); FHE.allow(f.totalRoyaltiesAccruedUSD, f.developer);
        FHE.allowThis(_totalRoyaltiesUSD);
        FHE.allowThis(_totalGovRevenueUSD);
        emit RoyaltyPeriodSettled(periodId, fieldId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRoyaltiesUSD, viewer);
        FHE.allow(_totalGovRevenueUSD, viewer);
    }
}
