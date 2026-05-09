// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MedicalTrialConsentVote
/// @notice Patients vote on clinical trial protocols with encrypted health risk
///         disclosures; IRB approves based on encrypted consent analytics.
contract MedicalTrialConsentVote is ZamaEthereumConfig, Ownable {
    struct Trial {
        string protocolTitle;
        string sponsorName;
        euint32 consentCount;
        euint32 refusalCount;
        euint32 pendingCount;
        uint256 deadline;
        bool approved;
        bool reviewed;
    }

    struct PatientRecord {
        euint8 riskTolerance;  // encrypted 1-10
        bool registered;
    }

    mapping(address => PatientRecord) private patients;
    mapping(address => mapping(uint256 => bool)) public hasConsented;
    Trial[] public trials;
    mapping(address => bool) public isIRB;
    euint8 private _minConsentRate; // encrypted minimum consent percentage

    event TrialRegistered(uint256 indexed id, string title);
    event ConsentSubmitted(uint256 indexed id, address patient);
    event IRBDecision(uint256 indexed id, bool approved);

    constructor(externalEuint8 encMinRate, bytes memory proof) Ownable(msg.sender) {
        _minConsentRate = FHE.fromExternal(encMinRate, proof);
        FHE.allowThis(_minConsentRate);
        isIRB[msg.sender] = true;
    }

    function addIRBMember(address m) external onlyOwner { isIRB[m] = true; }

    function registerPatient(address p, externalEuint8 encRisk, bytes calldata proof) external {
        require(isIRB[msg.sender], "Not IRB");
        euint8 risk = FHE.fromExternal(encRisk, proof);
        patients[p] = PatientRecord({ riskTolerance: risk, registered: true });
        FHE.allowThis(patients[p].riskTolerance);
        FHE.allow(patients[p].riskTolerance, p);
    }

    function registerTrial(string calldata title, string calldata sponsor, uint256 durationDays)
        external onlyOwner returns (uint256 id)
    {
        id = trials.length;
        trials.push(Trial({
            protocolTitle: title, sponsorName: sponsor,
            consentCount: FHE.asEuint32(0), refusalCount: FHE.asEuint32(0), pendingCount: FHE.asEuint32(0),
            deadline: block.timestamp + durationDays * 1 days, approved: false, reviewed: false
        }));
        FHE.allowThis(trials[id].consentCount);
        FHE.allowThis(trials[id].refusalCount);
        FHE.allowThis(trials[id].pendingCount);
        emit TrialRegistered(id, title);
    }

    function submitConsent(uint256 trialId, bool consent) external {
        require(patients[msg.sender].registered, "Not registered");
        require(!hasConsented[msg.sender][trialId], "Already submitted");
        require(block.timestamp < trials[trialId].deadline, "Expired");
        hasConsented[msg.sender][trialId] = true;
        if (consent) {
            trials[trialId].consentCount = FHE.add(trials[trialId].consentCount, FHE.asEuint32(1));
            FHE.allowThis(trials[trialId].consentCount);
        } else {
            trials[trialId].refusalCount = FHE.add(trials[trialId].refusalCount, FHE.asEuint32(1));
            FHE.allowThis(trials[trialId].refusalCount);
        }
        emit ConsentSubmitted(trialId, msg.sender);
    }

    function irbReview(uint256 trialId) external {
        require(isIRB[msg.sender], "Not IRB");
        Trial storage t = trials[trialId];
        require(!t.reviewed && block.timestamp >= t.deadline, "Not ready");
        t.reviewed = true;
        euint32 total = FHE.add(t.consentCount, t.refusalCount);
        // approval if consent rate >= threshold (simplified check)
        ebool hasConsents = FHE.gt(t.consentCount, t.refusalCount);
        t.approved = FHE.isInitialized(hasConsents);
        FHE.allow(t.consentCount, msg.sender);
        FHE.allow(t.refusalCount, msg.sender);
        FHE.allowThis(total);
        emit IRBDecision(trialId, t.approved);
    }

    function allowTrialData(uint256 trialId, address viewer) external {
        require(isIRB[msg.sender], "Not IRB");
        FHE.allow(trials[trialId].consentCount, viewer);
        FHE.allow(trials[trialId].refusalCount, viewer);
    }
}
