// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNaturalDisasterParametricInsurance
/// @notice Parametric insurance where payout triggers are based on encrypted
///         weather index readings, earthquake magnitudes, and flood levels.
///         Premiums and coverage amounts remain private between insurer and insured.
contract PrivateNaturalDisasterParametricInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DisasterType { HURRICANE, EARTHQUAKE, FLOOD, DROUGHT, WILDFIRE, TORNADO }
    enum PolicyStatus { QUOTE, BOUND, ACTIVE, CLAIMED, EXPIRED, CANCELLED }

    struct WeatherStation {
        string stationId;
        string location;
        euint32 latitudeE6;            // encrypted lat (microdegrees)
        euint32 longitudeE6;           // encrypted lon
        euint8  dataQualityScore;      // encrypted reliability 0-100
        bool active;
        bool certified;
    }

    struct ParametricPolicy {
        address insured;
        address insurer;
        DisasterType disasterType;
        uint256 weatherStationId;
        euint64 coverageAmountUSD;     // encrypted maximum payout
        euint64 annualPremiumUSD;      // encrypted annual premium
        euint32 triggerThreshold;      // encrypted (e.g., wind speed km/h, MMI scale*10, mm rain)
        euint32 exhaustionThreshold;   // encrypted full payout threshold
        euint64 accruedPremium;        // encrypted premium collected
        euint64 totalClaimsPaid;       // encrypted total paid
        uint256 inceptionDate;
        uint256 expiryDate;
        PolicyStatus status;
    }

    struct ClaimSubmission {
        uint256 policyId;
        uint256 stationId;
        euint32 measuredValue;         // encrypted observed trigger metric
        euint64 claimableAmount;       // encrypted computed payout
        uint256 eventDate;
        bool verified;
        bool paid;
    }

    mapping(uint256 => WeatherStation) private stations;
    mapping(uint256 => ParametricPolicy) private policies;
    mapping(uint256 => ClaimSubmission) private claims;
    mapping(address => bool) public isCertifiedOracle;
    mapping(address => bool) public isUnderwriter;
    uint256 public stationCount;
    uint256 public policyCount;
    uint256 public claimCount;
    euint64 private _totalExposureUSD;
    euint64 private _totalPremiumCollected;
    euint64 private _totalClaimsPaid;

    event StationRegistered(uint256 indexed stationId, string location);
    event PolicyBound(uint256 indexed policyId, DisasterType dtype);
    event ClaimTriggered(uint256 indexed claimId, uint256 policyId);
    event ClaimPaid(uint256 indexed claimId);
    event OracleCertified(address indexed oracle);

    constructor() Ownable(msg.sender) {
        _totalExposureUSD = FHE.asEuint64(0);
        _totalPremiumCollected = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalExposureUSD);
        FHE.allowThis(_totalPremiumCollected);
        FHE.allowThis(_totalClaimsPaid);
        isCertifiedOracle[msg.sender] = true;
        isUnderwriter[msg.sender] = true;
    }

    function certifyOracle(address oracle) external onlyOwner {
        isCertifiedOracle[oracle] = true;
        emit OracleCertified(oracle);
    }

    function addUnderwriter(address uw) external onlyOwner { isUnderwriter[uw] = true; }

    function registerStation(
        string calldata stationId,
        string calldata location,
        externalEuint32 encLat,   bytes calldata latProof,
        externalEuint32 encLon,   bytes calldata lonProof,
        externalEuint8  encQual,  bytes calldata qualProof
    ) external returns (uint256 sid) {
        require(isCertifiedOracle[msg.sender], "Not oracle");
        euint32 lat  = FHE.fromExternal(encLat, latProof);
        euint32 lon  = FHE.fromExternal(encLon, lonProof);
        euint8  qual = FHE.fromExternal(encQual, qualProof);
        sid = stationCount++;
        stations[sid] = WeatherStation({
            stationId: stationId,
            location: location,
            latitudeE6: lat,
            longitudeE6: lon,
            dataQualityScore: qual,
            active: true,
            certified: true
        });
        FHE.allowThis(stations[sid].latitudeE6);
        FHE.allowThis(stations[sid].longitudeE6);
        FHE.allowThis(stations[sid].dataQualityScore);
        emit StationRegistered(sid, location);
    }

    function bindPolicy(
        address insured,
        DisasterType dtype,
        uint256 stationId,
        externalEuint64 encCoverage,  bytes calldata covProof,
        externalEuint64 encPremium,   bytes calldata premProof,
        externalEuint32 encTrigger,   bytes calldata trigProof,
        externalEuint32 encExhaust,   bytes calldata exhProof,
        uint256 durationDays
    ) external returns (uint256 policyId) {
        require(isUnderwriter[msg.sender], "Not underwriter");
        euint64 coverage = FHE.fromExternal(encCoverage, covProof);
        euint64 coverageWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 coverageExposure = FHE.sub(coverageWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 premium  = FHE.fromExternal(encPremium, premProof);
        euint32 trigger  = FHE.fromExternal(encTrigger, trigProof);
        euint32 exhaust  = FHE.fromExternal(encExhaust, exhProof);
        policyId = policyCount++;
        ParametricPolicy storage _s0 = policies[policyId];
        _s0.insured = insured;
        _s0.insurer = msg.sender;
        _s0.disasterType = dtype;
        _s0.weatherStationId = stationId;
        _s0.coverageAmountUSD = coverage;
        _s0.annualPremiumUSD = premium;
        _s0.triggerThreshold = trigger;
        _s0.exhaustionThreshold = exhaust;
        _s0.accruedPremium = FHE.asEuint64(0);
        _s0.totalClaimsPaid = FHE.asEuint64(0);
        _s0.inceptionDate = block.timestamp;
        _s0.expiryDate = block.timestamp + durationDays * 1 days;
        _s0.status = PolicyStatus.ACTIVE;
        _totalExposureUSD = FHE.add(_totalExposureUSD, coverage);
        FHE.allowThis(policies[policyId].coverageAmountUSD);
        FHE.allow(policies[policyId].coverageAmountUSD, insured); // [acl_misconfig]
        FHE.allow(_totalExposureUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPremiumCollected, msg.sender); // [acl_misconfig]
        FHE.allowThis(policies[policyId].annualPremiumUSD);
        FHE.allow(policies[policyId].annualPremiumUSD, insured);
        FHE.allowThis(policies[policyId].triggerThreshold);
        FHE.allowThis(policies[policyId].exhaustionThreshold);
        FHE.allowThis(policies[policyId].accruedPremium);
        FHE.allowThis(policies[policyId].totalClaimsPaid);
        FHE.allow(policies[policyId].totalClaimsPaid, insured);
        FHE.allowThis(_totalExposureUSD);
        emit PolicyBound(policyId, dtype);
    }

    function payPremium(uint256 policyId, externalEuint64 encAmount, bytes calldata proof) external {
        require(policies[policyId].insured == msg.sender, "Not insured");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        policies[policyId].accruedPremium = FHE.add(policies[policyId].accruedPremium, amount);
        _totalPremiumCollected = FHE.add(_totalPremiumCollected, amount);
        FHE.allowThis(policies[policyId].accruedPremium);
        FHE.allowThis(_totalPremiumCollected);
    }

    function reportTriggerEvent(
        uint256 policyId,
        externalEuint32 encMeasured, bytes calldata proof,
        uint256 eventDate
    ) external returns (uint256 claimId) {
        require(isCertifiedOracle[msg.sender], "Not oracle");
        require(policies[policyId].status == PolicyStatus.ACTIVE, "Not active");
        euint32 measured = FHE.fromExternal(encMeasured, proof);
        ebool triggered = FHE.ge(measured, policies[policyId].triggerThreshold);
        // Calculate payout: linear interpolation between trigger and exhaustion
        ebool fullExhaust = FHE.ge(measured, policies[policyId].exhaustionThreshold);
        euint64 payout = FHE.select(fullExhaust,
            policies[policyId].coverageAmountUSD,
            FHE.div(policies[policyId].coverageAmountUSD, 2) // partial payout simplified
        );
        euint64 actualPayout = FHE.select(triggered, payout, FHE.asEuint64(0));
        claimId = claimCount++;
        claims[claimId] = ClaimSubmission({
            policyId: policyId,
            stationId: policies[policyId].weatherStationId,
            measuredValue: measured,
            claimableAmount: actualPayout,
            eventDate: eventDate,
            verified: true,
            paid: false
        });
        FHE.allowThis(claims[claimId].measuredValue);
        FHE.allowThis(claims[claimId].claimableAmount);
        FHE.allow(claims[claimId].claimableAmount, policies[policyId].insured);
        emit ClaimTriggered(claimId, policyId);
    }

    function processClaim(uint256 claimId) external nonReentrant {
        ClaimSubmission storage claim = claims[claimId];
        require(isUnderwriter[msg.sender], "Not underwriter");
        require(claim.verified && !claim.paid, "Invalid state");
        claim.paid = true;
        policies[claim.policyId].totalClaimsPaid = FHE.add(
            policies[claim.policyId].totalClaimsPaid, claim.claimableAmount
        );
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, claim.claimableAmount);
        FHE.allowThis(policies[claim.policyId].totalClaimsPaid);
        FHE.allowThis(_totalClaimsPaid);
        emit ClaimPaid(claimId);
    }

    function allowInsuranceStats(address viewer) external onlyOwner {
        FHE.allow(_totalExposureUSD, viewer);
        FHE.allow(_totalPremiumCollected, viewer);
        FHE.allow(_totalClaimsPaid, viewer);
    }
}
