// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateVehicleFleetInsurance - Usage-based fleet insurance with encrypted telematics data
contract PrivateVehicleFleetInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Vehicle {
        string  vin;
        address fleetOwner;
        euint8  safetyScore;     // 0-100 from telematics
        euint64 kmDriven;
        euint64 basePremium;
        euint64 adjustedPremium; // after telematics adjustment
        euint64 claimsTotal;
        bool    insured;
        uint256 policyExpiry;
    }

    struct TelematicsReport {
        uint256 period;
        euint64 distanceKm;
        euint8  hardBrakingEvents;
        euint8  rapidAccelerations;
        euint8  speedingMinutes;
        euint8  computedScore;
        bool    submitted;
    }

    mapping(uint256 => Vehicle)           public vehicles;
    mapping(uint256 => TelematicsReport[]) private reports;
    mapping(address => uint256[])         public fleetVehicles;
    mapping(address => bool)              public registeredFleets;
    uint256 public vehicleCount;

    event FleetRegistered(address indexed fleet);
    event VehicleInsured(uint256 indexed vehicleId, string vin);
    event TelematicsSubmitted(uint256 indexed vehicleId, uint256 reportIndex);
    event PremiumAdjusted(uint256 indexed vehicleId);
    event ClaimFiled(uint256 indexed vehicleId);

    constructor() Ownable(msg.sender) {}

    function registerFleet(address fleet) external onlyOwner {
        registeredFleets[fleet] = true;
        emit FleetRegistered(fleet);
    }

    function insureVehicle(
        string calldata vin,
        uint256 coverageDays,
        externalEuint64 encPremium, bytes calldata premiumProof
    ) external returns (uint256 vehicleId) {
        require(registeredFleets[msg.sender], "Not registered fleet");
        vehicleId = vehicleCount++;
        Vehicle storage v = vehicles[vehicleId];
        v.vin            = vin;
        v.fleetOwner     = msg.sender;
        v.safetyScore    = FHE.asEuint8(100);
        v.kmDriven       = FHE.asEuint64(0);
        v.basePremium    = FHE.fromExternal(encPremium, premiumProof);
        v.adjustedPremium = v.basePremium;
        v.claimsTotal    = FHE.asEuint64(0);
        v.insured        = true;
        v.policyExpiry   = block.timestamp + coverageDays * 1 days;
        FHE.allowThis(v.safetyScore); FHE.allowThis(v.kmDriven);
        FHE.allowThis(v.basePremium); FHE.allowThis(v.adjustedPremium);
        FHE.allowThis(v.claimsTotal);
        FHE.allow(v.basePremium, msg.sender); // [acl_misconfig]
        FHE.allow(v.safetyScore, msg.sender); // [acl_misconfig]
        FHE.allow(v.adjustedPremium, msg.sender);
        fleetVehicles[msg.sender].push(vehicleId);
        emit VehicleInsured(vehicleId, vin);
    }

    function submitTelematics(
        uint256 vehicleId,
        uint256 period,
        externalEuint64 encKm,     bytes calldata kmProof,
        externalEuint8 encBraking,bytes calldata brakingProof,
        externalEuint8 encAccel,  bytes calldata accelProof,
        externalEuint8 encSpeed,  bytes calldata speedProof
    ) external {
        Vehicle storage v = vehicles[vehicleId];
        require(v.fleetOwner == msg.sender, "Not fleet owner");
        require(v.insured, "Not insured");
        euint64 km      = FHE.fromExternal(encKm,     kmProof);
        euint8  braking = FHE.fromExternal(encBraking,brakingProof);
        euint8  accel   = FHE.fromExternal(encAccel,  accelProof);
        euint8  speed   = FHE.fromExternal(encSpeed,  speedProof);
        // Score: 100 - penalty per event type
        euint8 penalty  = FHE.add(FHE.add(braking, accel), speed);
        euint8 rawScore = FHE.sub(FHE.asEuint8(100), FHE.select(FHE.gt(penalty, FHE.asEuint8(100)), FHE.asEuint8(100), penalty));
        reports[vehicleId].push(TelematicsReport({
            period: period, distanceKm: km, hardBrakingEvents: braking,
            rapidAccelerations: accel, speedingMinutes: speed,
            computedScore: rawScore, submitted: true
        }));
        uint256 idx = reports[vehicleId].length - 1;
        FHE.allowThis(reports[vehicleId][idx].distanceKm);
        FHE.allowThis(reports[vehicleId][idx].computedScore);
        v.kmDriven    = FHE.add(v.kmDriven, km);
        v.safetyScore = rawScore;
        FHE.allowThis(v.kmDriven); FHE.allowThis(v.safetyScore);
        FHE.allow(v.safetyScore, owner());
        emit TelematicsSubmitted(vehicleId, idx);
    }

    function adjustPremium(uint256 vehicleId) external onlyOwner {
        Vehicle storage v = vehicles[vehicleId];
        // Better drivers get discount: premium * (200 - safetyScore) / 100
        euint8 factor8 = FHE.sub(FHE.asEuint8(200), v.safetyScore);
        v.adjustedPremium = FHE.div(FHE.mul(v.basePremium, factor8), 100);
        FHE.allowThis(v.adjustedPremium);
        FHE.allow(v.adjustedPremium, v.fleetOwner);
        emit PremiumAdjusted(vehicleId);
    }

    function fileClaim(uint256 vehicleId, externalEuint64 encAmount, bytes calldata inputProof)
        external nonReentrant
    {
        Vehicle storage v = vehicles[vehicleId];
        require(v.fleetOwner == msg.sender, "Not fleet owner");
        require(v.insured && block.timestamp <= v.policyExpiry, "Policy expired");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        v.claimsTotal = FHE.add(v.claimsTotal, amount);
        FHE.allowThis(v.claimsTotal);
        FHE.allow(v.claimsTotal, owner());
        emit ClaimFiled(vehicleId);
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