// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedClinicalPharmacogenomics
/// @notice Pharmacogenomics platform with encrypted genetic variant risk scores,
///         encrypted drug interaction severity, encrypted dosing recommendations.
contract EncryptedClinicalPharmacogenomics is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PatientProfile {
        euint8 cyp2d6Score;
        euint8 cyp2c19Score;
        euint64 polygenicRisk;
        euint64 adverseEventRisk;
        bool hasConsent;
    }

    struct DrugInteraction {
        string drug1;
        string drug2;
        euint8 severityLevel;
        euint64 frequencyBps;
        bool contraindicated;
    }

    struct DosingRecommendation {
        string drugName;
        euint64 recommendedDoseMg;
        euint8 confidenceScore;
        uint256 issuedAt;
    }

    mapping(address => PatientProfile) private profiles;
    mapping(uint256 => DrugInteraction) private interactions;
    mapping(uint256 => DosingRecommendation) private dosings;
    mapping(address => bool) public isPhysician;
    mapping(address => bool) public isGenomicsLab;
    uint256 public interactionCount;
    uint256 public dosingCount;

    event ProfileRegistered(address indexed patient);
    event InteractionRecorded(uint256 indexed id);
    event DosingIssued(uint256 indexed id, address indexed patient, string drug);
    event ConsentUpdated(address indexed patient, bool consent);

    constructor() Ownable(msg.sender) {
        isPhysician[msg.sender] = true;
        isGenomicsLab[msg.sender] = true;
    }

    function addPhysician(address p) external onlyOwner { isPhysician[p] = true; }
    function addLab(address l) external onlyOwner { isGenomicsLab[l] = true; }

    function registerProfile(
        address patient,
        externalEuint8 encCyp2d6, bytes calldata c1Proof,
        externalEuint8 encCyp2c19, bytes calldata c2Proof,
        externalEuint64 encPRS, bytes calldata prsProof,
        externalEuint64 encADR, bytes calldata adrProof
    ) external {
        require(isGenomicsLab[msg.sender], "Not lab");
        PatientProfile storage prof = profiles[patient];
        prof.cyp2d6Score = FHE.fromExternal(encCyp2d6, c1Proof);
        prof.cyp2c19Score = FHE.fromExternal(encCyp2c19, c2Proof);
        prof.polygenicRisk = FHE.fromExternal(encPRS, prsProof);
        prof.adverseEventRisk = FHE.fromExternal(encADR, adrProof);
        prof.hasConsent = false;
        FHE.allowThis(prof.cyp2d6Score);
        FHE.allowThis(prof.cyp2c19Score);
        FHE.allowThis(prof.polygenicRisk);
        FHE.allowThis(prof.adverseEventRisk);
        FHE.allow(prof.polygenicRisk, patient);
        FHE.allow(prof.adverseEventRisk, patient);
        emit ProfileRegistered(patient);
    }

    function setConsent(bool consent) external {
        profiles[msg.sender].hasConsent = consent;
        emit ConsentUpdated(msg.sender, consent);
    }

    function grantPhysicianAccess(address physician) external {
        require(profiles[msg.sender].hasConsent, "No consent");
        FHE.allow(profiles[msg.sender].cyp2d6Score, physician);
        FHE.allow(profiles[msg.sender].cyp2c19Score, physician);
        FHE.allow(profiles[msg.sender].polygenicRisk, physician);
        FHE.allow(profiles[msg.sender].adverseEventRisk, physician);
    }

    function recordInteraction(
        string calldata drug1, string calldata drug2,
        externalEuint8 encSeverity, bytes calldata sevProof,
        externalEuint64 encFreq, bytes calldata freqProof,
        bool contraindicated
    ) external returns (uint256 id) {
        require(isPhysician[msg.sender], "Not physician");
        euint8 severity = FHE.fromExternal(encSeverity, sevProof);
        euint64 freq = FHE.fromExternal(encFreq, freqProof);
        id = interactionCount++;
        interactions[id] = DrugInteraction({
            drug1: drug1, drug2: drug2,
            severityLevel: severity, frequencyBps: freq,
            contraindicated: contraindicated
        });
        FHE.allowThis(interactions[id].severityLevel);
        FHE.allowThis(interactions[id].frequencyBps);
        emit InteractionRecorded(id);
    }

    function issueDosing(
        address patient,
        string calldata drugName,
        externalEuint64 encDose, bytes calldata dProof,
        externalEuint8 encConfidence, bytes calldata cProof
    ) external returns (uint256 id) {
        require(isPhysician[msg.sender], "Not physician");
        require(profiles[patient].hasConsent, "No consent");
        euint64 dose = FHE.fromExternal(encDose, dProof);
        euint8 confidence = FHE.fromExternal(encConfidence, cProof);
        ebool highRisk = FHE.ge(profiles[patient].adverseEventRisk, FHE.asEuint64(7000));
        euint64 adjustedDose = FHE.select(highRisk, FHE.div(dose, 2), dose);
        id = dosingCount++;
        dosings[id] = DosingRecommendation({
            drugName: drugName,
            recommendedDoseMg: adjustedDose,
            confidenceScore: confidence,
            issuedAt: block.timestamp
        });
        FHE.allowThis(dosings[id].recommendedDoseMg);
        FHE.allowThis(dosings[id].confidenceScore);
        FHE.allow(dosings[id].recommendedDoseMg, patient);
        FHE.allow(dosings[id].recommendedDoseMg, msg.sender);
        emit DosingIssued(id, patient, drugName);
    }
}
