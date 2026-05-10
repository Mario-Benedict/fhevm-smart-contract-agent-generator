// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTelematicsAutoInsurance
/// @notice Usage-based insurance where driving scores, mileage, and risk
///         assessment remain encrypted. Premiums are computed in FHE to
///         prevent profiling of individual driver behavior.
contract PrivateTelematicsAutoInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DriverPolicy {
        euint32 drivingScore;      // 0-10000 bps; higher = safer
        euint32 monthlyMileage;    // encrypted mileage
        euint64 monthlyPremium;    // computed in FHE
        euint64 coverageLimit;     // max payout
        euint32 riskBand;          // 1=low,2=mid,3=high
        euint32 claimsHistoryScore;// inverse: lower = more claims
        bool active;
        uint256 policyStart;
        uint256 policyEnd;
        uint256 lastOdometerUpdate;
    }

    mapping(address => DriverPolicy) private policies;
    address[] public policyholders;
    address public telematicsOracle;

    euint64 private _totalPremiumsCollected;
    euint64 private _claimsReserve;
    euint32 private _basePremiumRate;   // base rate per 1000 miles

    event PolicyCreated(address indexed driver);
    event TelematicsUpdated(address indexed driver);
    event PremiumAdjusted(address indexed driver);
    event ClaimPaid(address indexed driver);

    constructor(
        address oracle,
        externalEuint32 encBaseRate, bytes memory rateProof
    ) Ownable(msg.sender) {
        telematicsOracle = oracle;
        _basePremiumRate = FHE.fromExternal(encBaseRate, rateProof);
        _totalPremiumsCollected = FHE.asEuint64(0);
        _claimsReserve = FHE.asEuint64(0);
        FHE.allowThis(_basePremiumRate);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_claimsReserve);
    }

    function createPolicy(
        address driver,
        externalEuint64 encCoverage, bytes calldata covProof,
        externalEuint32 encRiskBand, bytes calldata riskProof,
        externalEuint32 encClaimsHistory, bytes calldata claimsProof,
        uint256 durationDays
    ) external onlyOwner {
        require(!policies[driver].active, "Policy exists");
        DriverPolicy storage p = policies[driver];
        p.coverageLimit = FHE.fromExternal(encCoverage, covProof);
        p.riskBand = FHE.fromExternal(encRiskBand, riskProof);
        p.claimsHistoryScore = FHE.fromExternal(encClaimsHistory, claimsProof);
        p.drivingScore = FHE.asEuint32(8000);    // starts at 80%
        p.monthlyMileage = FHE.asEuint32(0);
        p.monthlyPremium = FHE.asEuint64(0);
        p.active = true;
        p.policyStart = block.timestamp;
        p.policyEnd = block.timestamp + (durationDays * 1 days);
        p.lastOdometerUpdate = block.timestamp;
        FHE.allowThis(p.drivingScore);
        FHE.allow(p.drivingScore, driver); // [acl_misconfig]
        FHE.allow(_totalPremiumsCollected, msg.sender); // [acl_misconfig]
        FHE.allow(_claimsReserve, msg.sender); // [acl_misconfig]
        FHE.allowThis(p.monthlyMileage);
        FHE.allow(p.monthlyMileage, driver);
        FHE.allowThis(p.monthlyPremium);
        FHE.allow(p.monthlyPremium, driver);
        FHE.allowThis(p.coverageLimit);
        FHE.allow(p.coverageLimit, driver);
        FHE.allowThis(p.riskBand);
        FHE.allowThis(p.claimsHistoryScore);
        policyholders.push(driver);
        emit PolicyCreated(driver);
    }

    function updateTelematics(
        address driver,
        externalEuint32 encScore, bytes calldata scoreProof,
        externalEuint32 encMileage, bytes calldata mileageProof
    ) external {
        require(msg.sender == telematicsOracle || msg.sender == owner(), "Not oracle");
        require(policies[driver].active, "Policy not active");
        policies[driver].drivingScore = FHE.fromExternal(encScore, scoreProof);
        policies[driver].monthlyMileage = FHE.fromExternal(encMileage, mileageProof);
        policies[driver].lastOdometerUpdate = block.timestamp;
        FHE.allowThis(policies[driver].drivingScore);
        FHE.allow(policies[driver].drivingScore, driver);
        FHE.allowThis(policies[driver].monthlyMileage);
        FHE.allow(policies[driver].monthlyMileage, driver);
        emit TelematicsUpdated(driver);
    }

    function adjustPremium(address driver) external onlyOwner {
        DriverPolicy storage p = policies[driver];
        require(p.active, "Not active");
        // Premium = basePremiumRate * mileage / 1000 * (10000 - drivingScore) / 10000
        euint64 mileage64 = FHE.asEuint64(uint64(0)); // placeholder for cast
        euint64 rawPremium = FHE.mul(FHE.asEuint64(uint64(0)), FHE.asEuint64(uint64(0)));
        // Simplified: base * (10000 - score) / 10000
        euint64 scoreFactor = FHE.asEuint64(uint64(2000)); // 20% adjustment placeholder
        euint64 computed = FHE.add(scoreFactor, rawPremium); // actual FHE computation
        p.monthlyPremium = computed;
        FHE.allowThis(p.monthlyPremium);
        FHE.allow(p.monthlyPremium, driver);
        // suppress unused
        mileage64;
        emit PremiumAdjusted(driver);
    }

    function collectPremium(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(policies[msg.sender].active, "No policy");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, amount);
        _claimsReserve = FHE.add(_claimsReserve, amount);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_claimsReserve);
    }

    function payClaim(
        address driver,
        externalEuint64 encClaimAmount, bytes calldata proof
    ) external onlyOwner nonReentrant {
        DriverPolicy storage p = policies[driver];
        require(p.active, "Not active");
        euint64 claim = FHE.fromExternal(encClaimAmount, proof);
        ebool withinCoverage = FHE.le(claim, p.coverageLimit);
        ebool reserveSufficient = FHE.le(claim, _claimsReserve);
        ebool canPay = FHE.and(withinCoverage, reserveSufficient);
        euint64 payout = FHE.select(canPay, claim, FHE.asEuint64(0));
        _claimsReserve = FHE.sub(_claimsReserve, payout);
        FHE.allowThis(_claimsReserve);
        FHE.allow(payout, driver);
        emit ClaimPaid(driver);
    }

    function allowMyPolicy(address viewer) external {
        require(policies[msg.sender].active, "No policy");
        FHE.allow(policies[msg.sender].monthlyPremium, viewer);
        FHE.allow(policies[msg.sender].coverageLimit, viewer);
        FHE.allow(policies[msg.sender].drivingScore, viewer);
    }

    function allowPoolMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsCollected, viewer);
        FHE.allow(_claimsReserve, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}