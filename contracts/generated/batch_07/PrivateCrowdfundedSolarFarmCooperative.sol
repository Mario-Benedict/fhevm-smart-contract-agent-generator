// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCrowdfundedSolarFarmCooperative
/// @notice Encrypted community solar cooperative: hidden individual investment shares,
///         confidential generation output per share, private net metering credit allocations,
///         and encrypted cooperative dividend distributions.
contract PrivateCrowdfundedSolarFarmCooperative is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ProjectStatus { Crowdfunding, Funded, Construction, Operating, Decommissioned }

    struct SolarProject {
        string projectName;
        string location;
        address projectManager;
        euint64 targetFundingUSD;      // encrypted funding target
        euint64 raisedFundingUSD;      // encrypted funds raised
        euint32 installedCapacityKW;   // encrypted capacity
        euint64 annualOutputKWh;       // encrypted annual generation
        euint64 totalDividendsPaidUSD; // encrypted dividends paid
        euint16 capacityFactorBps;     // encrypted capacity factor
        ProjectStatus status;
        uint256 fundingDeadline;
    }

    struct CooperativeMember {
        uint256 projectId;
        address member;
        euint64 investedAmountUSD;     // encrypted investment
        euint64 shareOfProjectBps;     // encrypted % share
        euint64 dividendEarnedUSD;     // encrypted dividend earned
        euint64 netMeteringCreditKWh;  // encrypted net metering credits
        uint256 joinedAt;
    }

    mapping(uint256 => SolarProject) private projects;
    mapping(uint256 => CooperativeMember) private cooperativeMembers;
    mapping(address => bool) public isCooperativeManager;

    uint256 public projectCount;
    uint256 public memberCount;
    euint64 private _totalInvestedUSD;
    euint64 private _totalDividendsUSD;

    event ProjectCreated(uint256 indexed id, string projectName);
    event MemberJoined(uint256 indexed memberId, uint256 projectId, address member);
    event DividendDistributed(uint256 indexed memberId, uint256 distributedAt);
    event ProjectStatusUpdated(uint256 indexed id, ProjectStatus newStatus);

    modifier onlyCooperativeManager() {
        require(isCooperativeManager[msg.sender] || msg.sender == owner(), "Not cooperative manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalInvestedUSD = FHE.asEuint64(0);
        _totalDividendsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalInvestedUSD);
        FHE.allowThis(_totalDividendsUSD);
        isCooperativeManager[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addManager(address m) external onlyOwner { isCooperativeManager[m] = true; }

    function createProject(
        string calldata projectName, string calldata location,
        externalEuint64 encTargetFunding, bytes calldata tfProof,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint16 encCapFactor, bytes calldata cfProof,
        uint256 fundingDeadlineDays
    ) external onlyCooperativeManager whenNotPaused returns (uint256 id) {
        euint64 targetFunding = FHE.fromExternal(encTargetFunding, tfProof);
        euint32 capacity = FHE.fromExternal(encCapacity, capProof);
        euint16 capFactor = FHE.fromExternal(encCapFactor, cfProof);
        id = projectCount++;
        projects[id].projectName = projectName;
        projects[id].location = location;
        projects[id].projectManager = msg.sender;
        projects[id].targetFundingUSD = targetFunding;
        projects[id].raisedFundingUSD = FHE.asEuint64(0);
        projects[id].installedCapacityKW = capacity;
        projects[id].annualOutputKWh = FHE.asEuint64(0);
        projects[id].totalDividendsPaidUSD = FHE.asEuint64(0);
        projects[id].capacityFactorBps = capFactor;
        projects[id].status = ProjectStatus.Crowdfunding;
        projects[id].fundingDeadline = block.timestamp + fundingDeadlineDays * 1 days;
        FHE.allowThis(projects[id].targetFundingUSD); FHE.allow(projects[id].targetFundingUSD, msg.sender);
        FHE.allowThis(projects[id].raisedFundingUSD); FHE.allow(projects[id].raisedFundingUSD, msg.sender);
        FHE.allowThis(projects[id].installedCapacityKW); FHE.allow(projects[id].installedCapacityKW, msg.sender);
        FHE.allowThis(projects[id].annualOutputKWh);
        FHE.allowThis(projects[id].totalDividendsPaidUSD); FHE.allow(projects[id].totalDividendsPaidUSD, msg.sender);
        FHE.allowThis(projects[id].capacityFactorBps);
        emit ProjectCreated(id, projectName);
    }

    function joinCooperative(
        uint256 projectId,
        externalEuint64 encInvestment, bytes calldata iProof,
        externalEuint64 encShareBps, bytes calldata sbProof
    ) external whenNotPaused nonReentrant returns (uint256 memberId) {
        SolarProject storage p = projects[projectId];
        require(p.status == ProjectStatus.Crowdfunding && block.timestamp < p.fundingDeadline, "Not funding");
        euint64 investment = FHE.fromExternal(encInvestment, iProof);
        euint64 shareBps = FHE.fromExternal(encShareBps, sbProof);
        memberId = memberCount++;
        cooperativeMembers[memberId] = CooperativeMember({
            projectId: projectId, member: msg.sender, investedAmountUSD: investment,
            shareOfProjectBps: shareBps, dividendEarnedUSD: FHE.asEuint64(0),
            netMeteringCreditKWh: FHE.asEuint64(0), joinedAt: block.timestamp
        });
        p.raisedFundingUSD = FHE.add(p.raisedFundingUSD, investment);
        _totalInvestedUSD = FHE.add(_totalInvestedUSD, investment);
        FHE.allowThis(cooperativeMembers[memberId].investedAmountUSD); FHE.allow(cooperativeMembers[memberId].investedAmountUSD, msg.sender);
        FHE.allowThis(cooperativeMembers[memberId].shareOfProjectBps); FHE.allow(cooperativeMembers[memberId].shareOfProjectBps, msg.sender);
        FHE.allowThis(cooperativeMembers[memberId].dividendEarnedUSD); FHE.allow(cooperativeMembers[memberId].dividendEarnedUSD, msg.sender);
        FHE.allowThis(cooperativeMembers[memberId].netMeteringCreditKWh); FHE.allow(cooperativeMembers[memberId].netMeteringCreditKWh, msg.sender);
        FHE.allowThis(p.raisedFundingUSD); FHE.allow(p.raisedFundingUSD, p.projectManager);
        FHE.allowThis(_totalInvestedUSD);
        emit MemberJoined(memberId, projectId, msg.sender);
    }

    function distributeDividend(
        uint256 memberId,
        externalEuint64 encDividend, bytes calldata dProof,
        externalEuint64 encNetMetering, bytes calldata nmProof
    ) external onlyCooperativeManager nonReentrant {
        CooperativeMember storage m = cooperativeMembers[memberId];
        euint64 dividend = FHE.fromExternal(encDividend, dProof);
        euint64 netMetering = FHE.fromExternal(encNetMetering, nmProof);
        m.dividendEarnedUSD = FHE.add(m.dividendEarnedUSD, dividend);
        m.netMeteringCreditKWh = FHE.add(m.netMeteringCreditKWh, netMetering);
        SolarProject storage p = projects[m.projectId];
        p.totalDividendsPaidUSD = FHE.add(p.totalDividendsPaidUSD, dividend);
        _totalDividendsUSD = FHE.add(_totalDividendsUSD, dividend);
        FHE.allowThis(m.dividendEarnedUSD); FHE.allow(m.dividendEarnedUSD, m.member);
        FHE.allowThis(m.netMeteringCreditKWh); FHE.allow(m.netMeteringCreditKWh, m.member);
        FHE.allowThis(p.totalDividendsPaidUSD); FHE.allow(p.totalDividendsPaidUSD, p.projectManager);
        FHE.allowThis(_totalDividendsUSD);
        emit DividendDistributed(memberId, block.timestamp);
    }

    function updateProjectStatus(uint256 projectId, ProjectStatus newStatus) external onlyCooperativeManager {
        projects[projectId].status = newStatus;
        emit ProjectStatusUpdated(projectId, newStatus);
    }

    function allowCoopStats(address viewer) external onlyOwner {
        FHE.allow(_totalInvestedUSD, viewer);
        FHE.allow(_totalDividendsUSD, viewer);
    }
}
