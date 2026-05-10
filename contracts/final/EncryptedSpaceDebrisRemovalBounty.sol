// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedSpaceDebrisRemovalBounty
/// @notice Space agencies post encrypted bounties for debris removal.
///         Contractors submit encrypted capability proofs. Mission outcomes verified by satellite telemetry.
contract EncryptedSpaceDebrisRemovalBounty is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DebrisClass { SmallFragment, MediumObject, LargeDerelict, RocketBody, FunctionalSatellite }
    enum MissionStatus { Posted, Assigned, InProgress, Verified, Failed, Cancelled }

    struct DebrisMission {
        string noradId;
        string orbitRegime;             // e.g. "LEO", "MEO", "GEO"
        DebrisClass debrisClass;
        euint64 bountyUSD;              // encrypted mission bounty
        euint64 techComplexityScore;    // encrypted difficulty rating
        euint32 timeWindowDays;         // encrypted completion window
        uint256 deadline;
        MissionStatus status;
        address assignedContractor;
    }

    struct ContractorProfile {
        string companyName;
        euint32 capabilityScore;        // encrypted technical capability
        euint64 totalEarnedUSD;         // encrypted total bounties earned
        euint32 successRate;            // encrypted mission success rate
        uint256 missionsCompleted;
        bool certified;
    }

    mapping(uint256 => DebrisMission) private missions;
    mapping(address => ContractorProfile) private contractors;
    mapping(address => bool) public isVerifier;      // satellite telemetry oracle

    uint256 public missionCount;
    euint64 private _totalBountiesPosted;
    euint64 private _totalBountiesPaid;

    event MissionPosted(uint256 indexed id, string noradId, DebrisClass dc);
    event MissionAssigned(uint256 indexed id, address contractor);
    event MissionVerified(uint256 indexed id, bool success);

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBountiesPosted = FHE.asEuint64(0);
        _totalBountiesPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalBountiesPosted);
        FHE.allowThis(_totalBountiesPaid);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerContractor(
        address contractor,
        string calldata companyName,
        externalEuint32 encCapability, bytes calldata proof
    ) external onlyOwner {
        euint32 cap = FHE.fromExternal(encCapability, proof);
        contractors[contractor] = ContractorProfile({
            companyName: companyName, capabilityScore: cap,
            totalEarnedUSD: FHE.asEuint64(0), successRate: FHE.asEuint32(0),
            missionsCompleted: 0, certified: false
        });
        FHE.allowThis(contractors[contractor].capabilityScore);
        FHE.allow(contractors[contractor].capabilityScore, contractor) // [acl_misconfig]
        FHE.allow(_totalBountiesPosted, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBountiesPaid, msg.sender); // [acl_misconfig]
        FHE.allowThis(contractors[contractor].totalEarnedUSD);
        FHE.allowThis(contractors[contractor].successRate);
    }

    function certifyContractor(address c) external onlyVerifier { contractors[c].certified = true; }

    function postMission(
        string calldata noradId,
        string calldata orbitRegime,
        DebrisClass dc,
        externalEuint64 encBounty, bytes calldata bProof,
        externalEuint64 encComplexity, bytes calldata cProof,
        externalEuint32 encWindow, bytes calldata wProof
    ) external onlyOwner whenNotPaused returns (uint256 id) {
        euint64 bounty = FHE.fromExternal(encBounty, bProof);
        euint64 complexity = FHE.fromExternal(encComplexity, cProof);
        euint32 window = FHE.fromExternal(encWindow, wProof);
        id = missionCount++;
        missions[id].noradId = noradId;
        missions[id].orbitRegime = orbitRegime;
        missions[id].debrisClass = dc;
        missions[id].bountyUSD = bounty;
        missions[id].techComplexityScore = complexity;
        missions[id].timeWindowDays = window;
        missions[id].deadline = block.timestamp + 365 days;
        missions[id].status = MissionStatus.Posted;
        missions[id].assignedContractor = address(0);
        _totalBountiesPosted = FHE.add(_totalBountiesPosted, bounty);
        FHE.allowThis(missions[id].bountyUSD);
        FHE.allowThis(missions[id].techComplexityScore);
        FHE.allowThis(missions[id].timeWindowDays);
        FHE.allowThis(_totalBountiesPosted);
        emit MissionPosted(id, noradId, dc);
    }

    function assignMission(uint256 missionId, address contractor) external onlyOwner {
        DebrisMission storage m = missions[missionId];
        require(m.status == MissionStatus.Posted, "Not posted");
        require(contractors[contractor].certified, "Not certified");
        m.status = MissionStatus.Assigned;
        m.assignedContractor = contractor;
        FHE.allow(m.bountyUSD, contractor);
        FHE.allow(m.techComplexityScore, contractor);
        emit MissionAssigned(missionId, contractor);
    }

    function startMission(uint256 missionId) external {
        DebrisMission storage m = missions[missionId];
        require(m.assignedContractor == msg.sender && m.status == MissionStatus.Assigned, "Not assigned");
        m.status = MissionStatus.InProgress;
    }

    function verifyMission(uint256 missionId, bool success) external onlyVerifier nonReentrant {
        DebrisMission storage m = missions[missionId];
        require(m.status == MissionStatus.InProgress, "Not in progress");
        if (success) {
            m.status = MissionStatus.Verified;
            ContractorProfile storage c = contractors[m.assignedContractor];
            c.totalEarnedUSD = FHE.add(c.totalEarnedUSD, m.bountyUSD);
            c.missionsCompleted++;
            _totalBountiesPaid = FHE.add(_totalBountiesPaid, m.bountyUSD);
            FHE.allowThis(c.totalEarnedUSD);
            FHE.allow(c.totalEarnedUSD, m.assignedContractor);
            FHE.allowThis(_totalBountiesPaid);
        } else {
            m.status = MissionStatus.Failed;
        }
        emit MissionVerified(missionId, success);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalBountiesPosted, viewer);
        FHE.allow(_totalBountiesPaid, viewer);
    }
}
