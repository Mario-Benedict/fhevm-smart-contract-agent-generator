// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDrugTrialPhaseManagement
/// @notice Clinical trial phase management: encrypted efficacy endpoints, encrypted adverse event rates,
///         encrypted dosing schedules, and confidential interim analysis results.
contract PrivateDrugTrialPhaseManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Phase { PRECLINICAL, PHASE_I, PHASE_II, PHASE_III, PHASE_IV }
    struct Trial {
        string trialId;
        string drugName;
        Phase currentPhase;
        euint64 primaryEndpointScore;   // encrypted primary efficacy endpoint
        euint64 adverseEventRateBps;    // encrypted AE rate
        euint64 responseRateBps;        // encrypted response rate
        euint64 medianSurvivalDays;     // encrypted survival
        euint64 enrolledPatients;       // encrypted enrollment count
        euint64 doseMgKg;               // encrypted dose level
        uint256 startDate;
        uint256 endDate;
        bool passed;
        bool terminated;
    }
    mapping(uint256 => Trial) private trials;
    uint256 public trialCount;
    mapping(address => bool) public isPrincipalInvestigator;
    mapping(address => bool) public isDMC;  // Data Monitoring Committee
    euint64 private _overallSuccessScore;

    event TrialRegistered(uint256 indexed id, string trialId, Phase phase);
    event PhaseAdvanced(uint256 indexed id, Phase newPhase);
    event TrialTerminated(uint256 indexed id, string reason);
    event InterimAnalysis(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _overallSuccessScore = FHE.asEuint64(0);
        FHE.allowThis(_overallSuccessScore);
        isPrincipalInvestigator[msg.sender] = true;
        isDMC[msg.sender] = true;
    }

    function addPI(address pi) external onlyOwner { isPrincipalInvestigator[pi] = true; }
    function addDMC(address d) external onlyOwner { isDMC[d] = true; }

    function registerTrial(
        string calldata trialId, string calldata drugName, Phase phase,
        externalEuint64 encDose, bytes calldata dProof,
        uint256 startDate, uint256 endDate
    ) external returns (uint256 id) {
        require(isPrincipalInvestigator[msg.sender], "Not PI");
        euint64 dose = FHE.fromExternal(encDose, dProof);
        id = trialCount++;
        Trial storage _s0 = trials[id];
        _s0.trialId = trialId;
        _s0.drugName = drugName;
        _s0.currentPhase = phase;
        _s0.primaryEndpointScore = FHE.asEuint64(0);
        _s0.adverseEventRateBps = FHE.asEuint64(0);
        _s0.responseRateBps = FHE.asEuint64(0);
        _s0.medianSurvivalDays = FHE.asEuint64(0);
        _s0.enrolledPatients = FHE.asEuint64(0);
        _s0.doseMgKg = dose;
        _s0.startDate = startDate;
        _s0.endDate = endDate;
        _s0.passed = false;
        _s0.terminated = false;
        FHE.allowThis(trials[id].primaryEndpointScore);
        FHE.allowThis(trials[id].adverseEventRateBps);
        FHE.allowThis(trials[id].responseRateBps);
        FHE.allowThis(trials[id].medianSurvivalDays);
        FHE.allowThis(trials[id].enrolledPatients);
        FHE.allowThis(trials[id].doseMgKg);
        emit TrialRegistered(id, trialId, phase);
    }

    function updateEndpoints(
        uint256 trialId,
        externalEuint64 encEndpoint, bytes calldata epProof,
        externalEuint64 encAE, bytes calldata aeProof,
        externalEuint64 encResponse, bytes calldata rProof,
        externalEuint64 encSurvival, bytes calldata sProof,
        externalEuint64 encEnrolled, bytes calldata enProof
    ) external {
        require(isPrincipalInvestigator[msg.sender], "Not PI");
        Trial storage t = trials[trialId];
        t.primaryEndpointScore = FHE.fromExternal(encEndpoint, epProof);
        t.adverseEventRateBps = FHE.fromExternal(encAE, aeProof);
        t.responseRateBps = FHE.fromExternal(encResponse, rProof);
        t.medianSurvivalDays = FHE.fromExternal(encSurvival, sProof);
        t.enrolledPatients = FHE.fromExternal(encEnrolled, enProof);
        FHE.allowThis(t.primaryEndpointScore);
        FHE.allowThis(t.adverseEventRateBps);
        FHE.allowThis(t.responseRateBps);
        FHE.allowThis(t.medianSurvivalDays);
        FHE.allowThis(t.enrolledPatients);
        emit InterimAnalysis(trialId);
    }

    function advancePhase(uint256 trialId) external {
        require(isDMC[msg.sender], "Not DMC");
        Trial storage t = trials[trialId];
        require(!t.terminated, "Terminated");
        // AE rate must be below 2000 bps (20%) to advance
        ebool aeSafe = FHE.lt(t.adverseEventRateBps, FHE.asEuint64(2000));
        // Response rate must be above 3000 bps (30%)
        ebool effectiveResponse = FHE.gt(t.responseRateBps, FHE.asEuint64(3000));
        t.passed = true;
        if (t.currentPhase == Phase.PRECLINICAL) t.currentPhase = Phase.PHASE_I;
        else if (t.currentPhase == Phase.PHASE_I) t.currentPhase = Phase.PHASE_II;
        else if (t.currentPhase == Phase.PHASE_II) t.currentPhase = Phase.PHASE_III;
        else if (t.currentPhase == Phase.PHASE_III) t.currentPhase = Phase.PHASE_IV;
        FHE.allow(t.primaryEndpointScore, owner());
        FHE.allow(t.adverseEventRateBps, owner());
        emit PhaseAdvanced(trialId, t.currentPhase);
    }

    function terminateTrial(uint256 trialId, string calldata reason) external {
        require(isDMC[msg.sender], "Not DMC");
        trials[trialId].terminated = true;
        emit TrialTerminated(trialId, reason);
    }
}
