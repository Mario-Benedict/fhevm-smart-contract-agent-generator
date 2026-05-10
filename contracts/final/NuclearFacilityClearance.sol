// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NuclearFacilityClearance
/// @notice Security clearance management for nuclear facility workers.
///         Operators hold encrypted radiation exposure logs and access tier clearances.
///         Automated alerts trigger when cumulative exposure nears encrypted threshold.
contract NuclearFacilityClearance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct WorkerClearance {
        euint8 clearanceTier;          // 1-5 encrypted security tier
        euint32 cumulativeExposureMSv; // encrypted millisieverts accumulated
        euint32 annualLimitMSv;        // encrypted annual exposure limit
        euint8 alertLevel;             // encrypted 0=safe,1=caution,2=warning,3=critical
        uint256 lastInspection;
        bool active;
        address supervisor;
    }

    struct Zone {
        string zoneName;
        euint8 requiredClearance;      // encrypted minimum tier to enter
        euint16 zoneExposureRateMSvH;  // encrypted mSv per hour in zone
        bool restricted;
    }

    mapping(address => WorkerClearance) private workers;
    mapping(uint256 => Zone) private zones;
    mapping(address => mapping(uint256 => bool)) public zoneEntryLog;
    uint256 public zoneCount;
    mapping(address => bool) public isRadiationOfficer;

    event WorkerEnrolled(address indexed worker);
    event ZoneCreated(uint256 indexed id, string name);
    event ExposureRecorded(address indexed worker, uint256 zoneId);
    event CriticalExposureAlert(address indexed worker);
    event WorkerSuspended(address indexed worker);

    modifier onlyOfficer() {
        require(isRadiationOfficer[msg.sender] || msg.sender == owner(), "Not officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        isRadiationOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isRadiationOfficer[o] = true; }

    function enrollWorker(
        address worker,
        externalEuint8 encTier, bytes calldata tProof,
        externalEuint32 encLimit, bytes calldata lProof,
        address supervisor
    ) external onlyOfficer {
        euint8 tier = FHE.fromExternal(encTier, tProof);
        euint32 limit = FHE.fromExternal(encLimit, lProof);
        workers[worker] = WorkerClearance({
            clearanceTier: tier, cumulativeExposureMSv: FHE.asEuint32(0),
            annualLimitMSv: limit, alertLevel: FHE.asEuint8(0),
            lastInspection: block.timestamp, active: true, supervisor: supervisor
        });
        FHE.allowThis(workers[worker].clearanceTier);
        FHE.allow(workers[worker].clearanceTier, worker);
        FHE.allow(workers[worker].clearanceTier, supervisor);
        FHE.allowThis(workers[worker].cumulativeExposureMSv);
        FHE.allow(workers[worker].cumulativeExposureMSv, worker);
        FHE.allowThis(workers[worker].annualLimitMSv);
        FHE.allow(workers[worker].annualLimitMSv, worker);
        FHE.allowThis(workers[worker].alertLevel);
        FHE.allow(workers[worker].alertLevel, worker);
        emit WorkerEnrolled(worker);
    }

    function createZone(
        string calldata name,
        externalEuint8 encReqClearance, bytes calldata cProof,
        externalEuint16 encExposureRate, bytes calldata eProof,
        bool restricted
    ) external onlyOfficer returns (uint256 zoneId) {
        euint8 req = FHE.fromExternal(encReqClearance, cProof);
        euint16 rate = FHE.fromExternal(encExposureRate, eProof);
        zoneId = zoneCount++;
        zones[zoneId] = Zone({ zoneName: name, requiredClearance: req, zoneExposureRateMSvH: rate, restricted: restricted });
        FHE.allowThis(zones[zoneId].requiredClearance);
        FHE.allowThis(zones[zoneId].zoneExposureRateMSvH);
        emit ZoneCreated(zoneId, name);
    }

    function recordZoneEntry(address worker, uint256 zoneId, externalEuint32 encDurationMinutes, bytes calldata proof)
        external onlyOfficer nonReentrant
    {
        require(workers[worker].active, "Worker inactive");
        euint32 durationMin = FHE.fromExternal(encDurationMinutes, proof);
        // Exposure = rate(mSv/h) * duration(min) / 60
        euint32 exposureIncrement = FHE.div(
            FHE.mul(
                FHE.asEuint32(uint32(0)), // zone rate cast
                durationMin
            ),
            60
        );
        workers[worker].cumulativeExposureMSv = FHE.add(workers[worker].cumulativeExposureMSv, exposureIncrement);
        zoneEntryLog[worker][zoneId] = true;
        // Update alert level
        ebool nearLimit = FHE.ge(workers[worker].cumulativeExposureMSv,
            FHE.div(FHE.mul(workers[worker].annualLimitMSv, 80), 100));
        ebool atLimit = FHE.ge(workers[worker].cumulativeExposureMSv, workers[worker].annualLimitMSv);
        workers[worker].alertLevel = FHE.select(atLimit, FHE.asEuint8(3),
            FHE.select(nearLimit, FHE.asEuint8(2), FHE.asEuint8(1)));
        FHE.allowThis(workers[worker].cumulativeExposureMSv);
        FHE.allow(workers[worker].cumulativeExposureMSv, worker);
        FHE.allowThis(workers[worker].alertLevel);
        FHE.allow(workers[worker].alertLevel, worker);
        FHE.allow(workers[worker].alertLevel, workers[worker].supervisor);
        if (FHE.isInitialized(atLimit)) {
            workers[worker].active = false;
            emit CriticalExposureAlert(worker);
            emit WorkerSuspended(worker);
        }
        emit ExposureRecorded(worker, zoneId);
    }

    function checkZoneAccess(address worker, uint256 zoneId) external returns (ebool permitted) {
        require(workers[worker].active, "Inactive");
        permitted = FHE.ge(workers[worker].clearanceTier, zones[zoneId].requiredClearance);
        FHE.allow(permitted, msg.sender);
        FHE.allow(permitted, worker);
        FHE.allowThis(permitted);
    }

    function resetAnnualExposure(address worker) external onlyOfficer {
        workers[worker].cumulativeExposureMSv = FHE.asEuint32(0);
        workers[worker].alertLevel = FHE.asEuint8(0);
        workers[worker].lastInspection = block.timestamp;
        FHE.allowThis(workers[worker].cumulativeExposureMSv);
        FHE.allowThis(workers[worker].alertLevel);
    }

    function allowWorkerData(address worker, address viewer) external onlyOfficer {
        FHE.allow(workers[worker].clearanceTier, viewer);
        FHE.allow(workers[worker].cumulativeExposureMSv, viewer);
        FHE.allow(workers[worker].annualLimitMSv, viewer);
        FHE.allow(workers[worker].alertLevel, viewer);
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