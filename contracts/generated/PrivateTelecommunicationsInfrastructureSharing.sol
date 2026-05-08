// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateTelecommunicationsInfrastructureSharing
/// @notice Confidential tower sharing agreement: encrypted tenancy fees, hidden utilization metrics,
///         private revenue splits between tower company and tenants, and encrypted SLA performance scores.
contract PrivateTelecommunicationsInfrastructureSharing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TowerType { Macro, Micro, Small, Rooftop, DAS, FiberNode }
    enum TenancyStatus { Active, Suspended, Terminated }

    struct TowerAsset {
        address towerOwner;
        string towerId;
        string location;
        TowerType towerType;
        euint8  maxTenants;           // encrypted max tenancy slots
        euint8  currentTenants;       // encrypted current tenancy count
        euint64 groundRentUSD;        // encrypted annual ground rent
        euint64 totalTenancyRevenueUSD; // encrypted accumulated revenue
        bool operational;
    }

    struct TenancyAgreement {
        uint256 towerId;
        address tenant;
        euint64 monthlyFeeUSD;        // encrypted monthly tenancy fee
        euint64 escalationBps;        // encrypted annual escalation
        euint16 slaScoreBps;          // encrypted SLA performance score
        euint64 totalPaidUSD;         // encrypted total paid by tenant
        TenancyStatus status;
        uint256 startDate;
    }

    mapping(uint256 => TowerAsset) private towers;
    mapping(uint256 => TenancyAgreement) private tenancies;
    mapping(address => bool) public isRegulator;

    uint256 public towerCount;
    uint256 public tenancyCount;
    euint64 private _totalPortfolioRevenueUSD;
    euint64 private _totalGroundRentPaidUSD;

    event TowerRegistered(uint256 indexed id, string towerId, TowerType towerType);
    event TenancyCreated(uint256 indexed tenancyId, uint256 towerId, address tenant);
    event MonthlyBillingSettled(uint256 indexed tenancyId, uint256 settledAt);
    event TenancyTerminated(uint256 indexed tenancyId);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPortfolioRevenueUSD = FHE.asEuint64(0);
        _totalGroundRentPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioRevenueUSD);
        FHE.allowThis(_totalGroundRentPaidUSD);
        isRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }

    function registerTower(
        string calldata towerId,
        string calldata location,
        TowerType towerType,
        externalEuint8 encMaxTenants, bytes calldata mtProof,
        externalEuint64 encGroundRent, bytes calldata grProof
    ) external whenNotPaused returns (uint256 id) {
        euint8 maxT = FHE.fromExternal(encMaxTenants, mtProof);
        euint64 groundRent = FHE.fromExternal(encGroundRent, grProof);
        id = towerCount++;
        towers[id] = TowerAsset({
            towerOwner: msg.sender, towerId: towerId, location: location, towerType: towerType,
            maxTenants: maxT, currentTenants: FHE.asEuint8(0),
            groundRentUSD: groundRent, totalTenancyRevenueUSD: FHE.asEuint64(0), operational: true
        });
        FHE.allowThis(towers[id].maxTenants); FHE.allow(towers[id].maxTenants, msg.sender);
        FHE.allowThis(towers[id].currentTenants); FHE.allow(towers[id].currentTenants, msg.sender);
        FHE.allowThis(towers[id].groundRentUSD); FHE.allow(towers[id].groundRentUSD, msg.sender);
        FHE.allowThis(towers[id].totalTenancyRevenueUSD); FHE.allow(towers[id].totalTenancyRevenueUSD, msg.sender);
        emit TowerRegistered(id, towerId, towerType);
    }

    function createTenancy(
        uint256 towerId,
        address tenant,
        externalEuint64 encMonthlyFee, bytes calldata mfProof,
        externalEuint64 encEscalation, bytes calldata escProof
    ) external whenNotPaused returns (uint256 tenancyId) {
        TowerAsset storage t = towers[towerId];
        require(msg.sender == t.towerOwner || msg.sender == owner(), "Not tower owner");
        euint64 monthlyFee = FHE.fromExternal(encMonthlyFee, mfProof);
        euint64 escalation = FHE.fromExternal(encEscalation, escProof);
        t.currentTenants = FHE.add(t.currentTenants, FHE.asEuint8(1));
        tenancyId = tenancyCount++;
        tenancies[tenancyId] = TenancyAgreement({
            towerId: towerId, tenant: tenant, monthlyFeeUSD: monthlyFee,
            escalationBps: escalation, slaScoreBps: FHE.asEuint16(10000),
            totalPaidUSD: FHE.asEuint64(0), status: TenancyStatus.Active, startDate: block.timestamp
        });
        FHE.allowThis(tenancies[tenancyId].monthlyFeeUSD); FHE.allow(tenancies[tenancyId].monthlyFeeUSD, tenant); FHE.allow(tenancies[tenancyId].monthlyFeeUSD, t.towerOwner);
        FHE.allowThis(tenancies[tenancyId].escalationBps);
        FHE.allowThis(tenancies[tenancyId].slaScoreBps); FHE.allow(tenancies[tenancyId].slaScoreBps, tenant);
        FHE.allowThis(tenancies[tenancyId].totalPaidUSD); FHE.allow(tenancies[tenancyId].totalPaidUSD, tenant);
        FHE.allowThis(t.currentTenants); FHE.allow(t.currentTenants, t.towerOwner);
        emit TenancyCreated(tenancyId, towerId, tenant);
    }

    function settleMonthlyBilling(uint256 tenancyId) external nonReentrant {
        TenancyAgreement storage ta = tenancies[tenancyId];
        require(ta.status == TenancyStatus.Active, "Tenancy not active");
        TowerAsset storage t = towers[ta.towerId];
        require(msg.sender == t.towerOwner || msg.sender == owner(), "Not authorized");
        ta.totalPaidUSD = FHE.add(ta.totalPaidUSD, ta.monthlyFeeUSD);
        t.totalTenancyRevenueUSD = FHE.add(t.totalTenancyRevenueUSD, ta.monthlyFeeUSD);
        _totalPortfolioRevenueUSD = FHE.add(_totalPortfolioRevenueUSD, ta.monthlyFeeUSD);
        FHE.allowThis(ta.totalPaidUSD); FHE.allow(ta.totalPaidUSD, ta.tenant);
        FHE.allowThis(t.totalTenancyRevenueUSD); FHE.allow(t.totalTenancyRevenueUSD, t.towerOwner);
        FHE.allowThis(_totalPortfolioRevenueUSD);
        emit MonthlyBillingSettled(tenancyId, block.timestamp);
    }

    function updateSLAScore(
        uint256 tenancyId,
        externalEuint16 encScore, bytes calldata proof
    ) external onlyRegulator {
        TenancyAgreement storage ta = tenancies[tenancyId];
        ta.slaScoreBps = FHE.fromExternal(encScore, proof);
        FHE.allowThis(ta.slaScoreBps); FHE.allow(ta.slaScoreBps, ta.tenant);
    }

    function terminateTenancy(uint256 tenancyId) external {
        TenancyAgreement storage ta = tenancies[tenancyId];
        TowerAsset storage t = towers[ta.towerId];
        require(msg.sender == t.towerOwner || msg.sender == owner(), "Not authorized");
        ta.status = TenancyStatus.Terminated;
        t.currentTenants = FHE.sub(t.currentTenants, FHE.asEuint8(1));
        FHE.allowThis(t.currentTenants); FHE.allow(t.currentTenants, t.towerOwner);
        emit TenancyTerminated(tenancyId);
    }

    function allowPortfolioView(address viewer) external onlyOwner {
        FHE.allow(_totalPortfolioRevenueUSD, viewer);
        FHE.allow(_totalGroundRentPaidUSD, viewer);
    }
}
