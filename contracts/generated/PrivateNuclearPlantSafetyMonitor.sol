// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNuclearPlantSafetyMonitor
/// @notice Nuclear power plant safety monitoring: encrypted reactor core temperature, encrypted neutron flux,
///         encrypted coolant pressure, encrypted radiation dose rates, and confidential safety margin calculations.
contract PrivateNuclearPlantSafetyMonitor is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ReactorUnit {
        string unitId;
        euint64 coreTemperatureK;     // encrypted core temp in Kelvin * 10
        euint64 neutronFluxSv;        // encrypted neutron flux (Sv/h * 1000)
        euint64 coolantPressurePa;    // encrypted coolant pressure
        euint64 steamFlowKgs;         // encrypted steam flow kg/s
        euint64 radiationDoseMuSvH;   // encrypted dose rate μSv/h
        euint64 safetyMarginBps;      // encrypted safety margin (0=critical, 10000=full)
        euint64 powerOutputMW;        // encrypted electrical output
        bool inScram;                 // SCRAM = emergency shutdown
        bool operational;
        uint256 lastReadingTime;
    }

    struct SafetyIncident {
        uint256 unitId;
        euint64 severity;             // encrypted severity 0-1000
        euint64 radiationReleased;    // encrypted release in μSv
        string incidentType;
        uint256 incidentTime;
        bool contained;
    }

    struct OperatorShift {
        address operator_;
        uint256 unitId;
        euint64 stressScore;          // encrypted operator stress level (fatigue)
        uint256 shiftStart;
        uint256 shiftEnd;
        bool active;
    }

    mapping(uint256 => ReactorUnit) private units;
    mapping(uint256 => SafetyIncident[]) private incidents;
    mapping(uint256 => OperatorShift) private shifts;
    uint256 public unitCount;
    uint256 public shiftCount;
    euint64 private _totalRadiationReleased;
    mapping(address => bool) public isSafetyEngineer;
    mapping(address => bool) public isRegulator;
    mapping(address => bool) public isSensorOracle;

    event UnitRegistered(uint256 indexed id, string unitId);
    event ReadingUpdated(uint256 indexed unitId);
    event ScramInitiated(uint256 indexed unitId, string reason);
    event IncidentReported(uint256 indexed unitId, uint256 incidentIdx);
    event SafetyMarginAlert(uint256 indexed unitId);

    constructor() Ownable(msg.sender) {
        _totalRadiationReleased = FHE.asEuint64(0);
        FHE.allowThis(_totalRadiationReleased);
        isSafetyEngineer[msg.sender] = true;
        isRegulator[msg.sender] = true;
        isSensorOracle[msg.sender] = true;
    }

    function addEngineer(address e) external onlyOwner { isSafetyEngineer[e] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function addOracle(address o) external onlyOwner { isSensorOracle[o] = true; }

    function registerUnit(string calldata unitId) external returns (uint256 id) {
        require(isSafetyEngineer[msg.sender], "Not engineer");
        id = unitCount++;
        units[id] = ReactorUnit({
            unitId: unitId, coreTemperatureK: FHE.asEuint64(5730),
            neutronFluxSv: FHE.asEuint64(0), coolantPressurePa: FHE.asEuint64(155000),
            steamFlowKgs: FHE.asEuint64(0), radiationDoseMuSvH: FHE.asEuint64(0),
            safetyMarginBps: FHE.asEuint64(9000), powerOutputMW: FHE.asEuint64(0),
            inScram: false, operational: true, lastReadingTime: block.timestamp
        });
        FHE.allowThis(units[id].coreTemperatureK);
        FHE.allowThis(units[id].neutronFluxSv);
        FHE.allowThis(units[id].coolantPressurePa);
        FHE.allowThis(units[id].steamFlowKgs);
        FHE.allowThis(units[id].radiationDoseMuSvH);
        FHE.allowThis(units[id].safetyMarginBps);
        FHE.allowThis(units[id].powerOutputMW);
        emit UnitRegistered(id, unitId);
    }

    function updateReadings(
        uint256 unitId,
        externalEuint64 encTemp, bytes calldata tProof,
        externalEuint64 encFlux, bytes calldata fProof,
        externalEuint64 encPressure, bytes calldata pProof,
        externalEuint64 encDose, bytes calldata dProof,
        externalEuint64 encPower, bytes calldata powProof
    ) external {
        require(isSensorOracle[msg.sender], "Not oracle");
        ReactorUnit storage u = units[unitId];
        require(!u.inScram, "In SCRAM");
        u.coreTemperatureK = FHE.fromExternal(encTemp, tProof);
        u.neutronFluxSv = FHE.fromExternal(encFlux, fProof);
        u.coolantPressurePa = FHE.fromExternal(encPressure, pProof);
        u.radiationDoseMuSvH = FHE.fromExternal(encDose, dProof);
        u.powerOutputMW = FHE.fromExternal(encPower, powProof);
        u.lastReadingTime = block.timestamp;
        // Safety margin: decreases if temp > 6000K or dose > 1000
        ebool overTemp = FHE.gt(u.coreTemperatureK, FHE.asEuint64(6000));
        ebool overDose = FHE.gt(u.radiationDoseMuSvH, FHE.asEuint64(1000));
        u.safetyMarginBps = FHE.select(FHE.or(overTemp, overDose),
            FHE.sub(u.safetyMarginBps, FHE.asEuint64(500)), u.safetyMarginBps);
        FHE.allowThis(u.coreTemperatureK);
        FHE.allowThis(u.neutronFluxSv);
        FHE.allowThis(u.coolantPressurePa);
        FHE.allowThis(u.radiationDoseMuSvH);
        FHE.allowThis(u.powerOutputMW);
        FHE.allowThis(u.safetyMarginBps);
        FHE.allow(u.safetyMarginBps, owner());
        emit ReadingUpdated(unitId);
    }

    function initiateScram(uint256 unitId, string calldata reason) external {
        require(isSafetyEngineer[msg.sender], "Not engineer");
        units[unitId].inScram = true;
        units[unitId].operational = false;
        emit ScramInitiated(unitId, reason);
    }

    function reportIncident(
        uint256 unitId, string calldata incidentType,
        externalEuint64 encSeverity, bytes calldata sevProof,
        externalEuint64 encRelease, bytes calldata relProof
    ) external {
        require(isSafetyEngineer[msg.sender] || isRegulator[msg.sender], "Not authorized");
        euint64 severity = FHE.fromExternal(encSeverity, sevProof);
        euint64 release = FHE.fromExternal(encRelease, relProof);
        incidents[unitId].push(SafetyIncident({
            unitId: unitId, severity: severity, radiationReleased: release,
            incidentType: incidentType, incidentTime: block.timestamp, contained: false
        }));
        uint256 idx = incidents[unitId].length - 1;
        _totalRadiationReleased = FHE.add(_totalRadiationReleased, release);
        FHE.allowThis(incidents[unitId][idx].severity);
        FHE.allowThis(incidents[unitId][idx].radiationReleased);
        FHE.allowThis(_totalRadiationReleased);
        FHE.allow(incidents[unitId][idx].severity, isRegulator[msg.sender] ? msg.sender : owner());
        emit IncidentReported(unitId, idx);
    }

    function containIncident(uint256 unitId, uint256 incidentIdx) external {
        require(isSafetyEngineer[msg.sender], "Not engineer");
        incidents[unitId][incidentIdx].contained = true;
    }

    function grantRegulatorAccess(uint256 unitId, address regulator) external {
        require(isRegulator[msg.sender], "Not regulator");
        FHE.allow(units[unitId].coreTemperatureK, regulator);
        FHE.allow(units[unitId].radiationDoseMuSvH, regulator);
        FHE.allow(units[unitId].safetyMarginBps, regulator);
    }
}
