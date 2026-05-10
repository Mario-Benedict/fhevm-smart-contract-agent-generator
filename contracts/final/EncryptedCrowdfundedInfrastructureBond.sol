// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCrowdfundedInfrastructureBond
/// @notice Municipal infrastructure crowdfunding bond: encrypted funding targets, encrypted yield rates,
///         encrypted investor positions, and confidential project milestone tracking.
contract EncryptedCrowdfundedInfrastructureBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InfrastructureType { ROAD, BRIDGE, WATER_TREATMENT, SOLAR_FARM, HOSPITAL, SCHOOL }
    enum MilestoneStatus { PENDING, IN_PROGRESS, COMPLETED, DELAYED }

    struct InfrastructureBond {
        string projectName;
        InfrastructureType infraType;
        euint64 fundingTargetUSD;   // encrypted funding goal
        euint64 raisedSoFarUSD;     // encrypted amount raised
        euint64 yieldRateBps;       // encrypted annual yield
        euint64 minInvestmentUSD;   // encrypted minimum investment
        euint64 maxInvestmentUSD;   // encrypted maximum per investor
        uint256 fundingDeadline;
        uint256 bondMaturity;
        bool fundingComplete;
        bool matured;
    }

    struct Milestone {
        string description;
        euint64 costAllocatedUSD;   // encrypted budget for this milestone
        euint64 costActualUSD;      // encrypted actual cost
        MilestoneStatus status;
        uint256 targetDate;
        uint256 completedDate;
    }

    struct InvestorPosition {
        euint64 investedUSD;       // encrypted investment
        euint64 yieldEarned;       // encrypted yield accumulated
        euint64 principalPaid;     // encrypted principal returned
        uint256 investmentDate;
        bool redeemed;
    }

    mapping(uint256 => InfrastructureBond) private bonds;
    mapping(uint256 => Milestone[]) private milestones;
    mapping(uint256 => mapping(address => InvestorPosition)) private positions;
    uint256 public bondCount;
    euint64 private _totalInfraFunding;
    mapping(address => bool) public isMunicipalAuthority;
    mapping(address => bool) public isAuditor;

    event BondIssued(uint256 indexed id, string projectName, InfrastructureType infraType);
    event InvestmentMade(uint256 indexed bondId, address investor);
    event MilestoneAdded(uint256 indexed bondId, uint256 milestoneIndex);
    event MilestoneUpdated(uint256 indexed bondId, uint256 milestoneIndex, MilestoneStatus status);
    event YieldDistributed(uint256 indexed bondId);
    event BondMatured(uint256 indexed bondId);

    constructor() Ownable(msg.sender) {
        _totalInfraFunding = FHE.asEuint64(0);
        FHE.allowThis(_totalInfraFunding);
        isMunicipalAuthority[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isMunicipalAuthority[a] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }

    function issueBond(
        string calldata name, InfrastructureType infraType,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint64 encYield, bytes calldata yProof,
        externalEuint64 encMin, bytes calldata minProof,
        externalEuint64 encMax, bytes calldata maxProof,
        uint256 fundingDeadline, uint256 maturity
    ) external returns (uint256 id) {
        require(isMunicipalAuthority[msg.sender], "Not authority");
        euint64 target = FHE.fromExternal(encTarget, tProof);
        euint64 yield_ = FHE.fromExternal(encYield, yProof);
        euint64 min = FHE.fromExternal(encMin, minProof);
        euint64 max = FHE.fromExternal(encMax, maxProof);
        id = bondCount++;
        bonds[id].projectName = name;
        bonds[id].infraType = infraType;
        bonds[id].fundingTargetUSD = target;
        bonds[id].raisedSoFarUSD = FHE.asEuint64(0);
        bonds[id].yieldRateBps = yield_;
        bonds[id].minInvestmentUSD = min;
        bonds[id].maxInvestmentUSD = max;
        bonds[id].fundingDeadline = fundingDeadline;
        bonds[id].bondMaturity = maturity;
        bonds[id].fundingComplete = false;
        bonds[id].matured = false;
        FHE.allowThis(bonds[id].fundingTargetUSD);
        FHE.allowThis(bonds[id].raisedSoFarUSD);
        FHE.allowThis(bonds[id].yieldRateBps);
        FHE.allowThis(bonds[id].minInvestmentUSD);
        FHE.allowThis(bonds[id].maxInvestmentUSD);
        emit BondIssued(id, name, infraType);
    }

    function invest(
        uint256 bondId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        InfrastructureBond storage bond = bonds[bondId];
        require(!bond.fundingComplete && block.timestamp < bond.fundingDeadline, "Not open");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Enforce min/max
        ebool aboveMin = FHE.ge(amount, bond.minInvestmentUSD);
        ebool belowMax = FHE.le(amount, bond.maxInvestmentUSD);
        euint64 actualAmount = FHE.select(FHE.and(aboveMin, belowMax), amount, bond.minInvestmentUSD);
        // Cap at remaining target
        ebool _safeSub195 = FHE.ge(bond.fundingTargetUSD, bond.raisedSoFarUSD);
        euint64 remaining = FHE.select(_safeSub195, FHE.sub(bond.fundingTargetUSD, bond.raisedSoFarUSD), FHE.asEuint64(0));
        ebool withinRemaining = FHE.le(actualAmount, remaining);
        actualAmount = FHE.select(withinRemaining, actualAmount, remaining);
        InvestorPosition storage pos = positions[bondId][msg.sender];
        if (!FHE.isInitialized(pos.investedUSD)) {
            pos.investedUSD = FHE.asEuint64(0);
            pos.yieldEarned = FHE.asEuint64(0);
            pos.principalPaid = FHE.asEuint64(0);
            pos.investmentDate = block.timestamp;
            FHE.allowThis(pos.investedUSD);
            FHE.allowThis(pos.yieldEarned);
            FHE.allowThis(pos.principalPaid);
        }
        pos.investedUSD = FHE.add(pos.investedUSD, actualAmount);
        bond.raisedSoFarUSD = FHE.add(bond.raisedSoFarUSD, actualAmount);
        _totalInfraFunding = FHE.add(_totalInfraFunding, actualAmount);
        FHE.allowThis(pos.investedUSD);
        FHE.allow(pos.investedUSD, msg.sender);
        FHE.allowThis(bond.raisedSoFarUSD);
        FHE.allowThis(_totalInfraFunding);
        emit InvestmentMade(bondId, msg.sender);
    }

    function addMilestone(
        uint256 bondId, string calldata description,
        externalEuint64 encCost, bytes calldata cProof,
        uint256 targetDate
    ) external {
        require(isMunicipalAuthority[msg.sender], "Not authority");
        euint64 cost = FHE.fromExternal(encCost, cProof);
        milestones[bondId].push(Milestone({
            description: description, costAllocatedUSD: cost,
            costActualUSD: FHE.asEuint64(0),
            status: MilestoneStatus.PENDING,
            targetDate: targetDate, completedDate: 0
        }));
        uint256 idx = milestones[bondId].length - 1;
        FHE.allowThis(milestones[bondId][idx].costAllocatedUSD);
        FHE.allowThis(milestones[bondId][idx].costActualUSD);
        emit MilestoneAdded(bondId, idx);
    }

    function updateMilestone(
        uint256 bondId, uint256 milestoneIdx,
        MilestoneStatus status,
        externalEuint64 encActualCost, bytes calldata cProof
    ) external {
        require(isAuditor[msg.sender], "Not auditor");
        Milestone storage ms = milestones[bondId][milestoneIdx];
        euint64 actualCost = FHE.fromExternal(encActualCost, cProof);
        ms.status = status;
        ms.costActualUSD = actualCost;
        if (status == MilestoneStatus.COMPLETED) {
            ms.completedDate = block.timestamp;
        }
        FHE.allowThis(ms.costActualUSD);
        FHE.allow(ms.costActualUSD, owner());
        emit MilestoneUpdated(bondId, milestoneIdx, status);
    }

    function distributeYield(uint256 bondId, address[] calldata investors) external {
        require(isMunicipalAuthority[msg.sender], "Not authority");
        InfrastructureBond storage bond = bonds[bondId];
        for (uint256 i = 0; i < investors.length; i++) {
            InvestorPosition storage pos = positions[bondId][investors[i]];
            if (!FHE.isInitialized(pos.investedUSD)) continue;
            euint64 annualYield = FHE.div(FHE.mul(pos.investedUSD, bond.yieldRateBps), 10000);
            euint64 quarterlyYield = FHE.div(annualYield, 4);
            pos.yieldEarned = FHE.add(pos.yieldEarned, quarterlyYield);
            FHE.allowThis(pos.yieldEarned);
            FHE.allow(pos.yieldEarned, investors[i]);
        }
        emit YieldDistributed(bondId);
    }

    function matureBond(uint256 bondId, address[] calldata investors) external nonReentrant {
        require(isMunicipalAuthority[msg.sender], "Not authority");
        InfrastructureBond storage bond = bonds[bondId];
        require(block.timestamp >= bond.bondMaturity && !bond.matured, "Not ready");
        bond.matured = true;
        for (uint256 i = 0; i < investors.length; i++) {
            InvestorPosition storage pos = positions[bondId][investors[i]];
            if (!FHE.isInitialized(pos.investedUSD) || pos.redeemed) continue;
            pos.principalPaid = pos.investedUSD;
            pos.redeemed = true;
            FHE.allowThis(pos.principalPaid);
            FHE.allow(pos.principalPaid, investors[i]);
            FHE.allow(pos.yieldEarned, investors[i]);
        }
        emit BondMatured(bondId);
    }
}
