// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedAircraftEngineLeaseTracker
/// @notice Aviation engine lease management where monthly rental rates,
///         maintenance reserve contributions, and lessee credit scores
///         are encrypted. Enables confidential multi-lessor negotiations.
contract EncryptedAircraftEngineLeaseTracker is ZamaEthereumConfig, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant LESSOR_ROLE = keccak256("LESSOR_ROLE");
    bytes32 public constant LESSEE_ROLE = keccak256("LESSEE_ROLE");
    bytes32 public constant APPRAISER_ROLE = keccak256("APPRAISER_ROLE");

    enum LeaseStatus { Negotiating, Active, Suspended, Terminated, Expired }

    struct Engine {
        string serialNumber;
        string engineType;        // e.g., "CFM56-7B"
        address lessor;
        euint64 currentAppraisedValue; // encrypted appraisal
        bool available;
    }

    struct EngineLease {
        uint256 engineId;
        address lessee;
        euint64 monthlyRent;            // encrypted monthly rent
        euint64 maintenanceReserve;     // encrypted maint reserve per flight hour
        euint32 creditScore;            // encrypted lessee credit score
        euint64 securityDeposit;        // encrypted security deposit
        euint64 totalPaid;              // encrypted cumulative payments
        uint256 startDate;
        uint256 endDate;
        LeaseStatus status;
    }

    uint256 public nextEngineId;
    uint256 public nextLeaseId;
    mapping(uint256 => Engine) private engines;
    mapping(uint256 => EngineLease) private leases;
    mapping(address => uint256[]) private lesseeLeases;
    mapping(address => uint256[]) private lessorEngines;

    event EngineRegistered(uint256 indexed engineId, string serialNumber);
    event LeaseNegotiated(uint256 indexed leaseId, uint256 engineId, address lessee);
    event LeaseActivated(uint256 indexed leaseId);
    event PaymentRecorded(uint256 indexed leaseId);
    event LeaseTerminated(uint256 indexed leaseId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LESSOR_ROLE, msg.sender);
        _grantRole(APPRAISER_ROLE, msg.sender);
    }

    function registerEngine(
        string calldata serialNumber,
        string calldata engineType,
        externalEuint64 encValue,
        bytes calldata valueProof
    ) external onlyRole(LESSOR_ROLE) returns (uint256 engineId) {
        engineId = nextEngineId++;
        euint64 value = FHE.fromExternal(encValue, valueProof);
        engines[engineId] = Engine({
            serialNumber: serialNumber,
            engineType: engineType,
            lessor: msg.sender,
            currentAppraisedValue: value,
            available: true
        });
        FHE.allowThis(engines[engineId].currentAppraisedValue);
        FHE.allow(engines[engineId].currentAppraisedValue, msg.sender);
        lessorEngines[msg.sender].push(engineId);
        emit EngineRegistered(engineId, serialNumber);
    }

    function updateAppraisal(
        uint256 engineId,
        externalEuint64 encValue,
        bytes calldata proof
    ) external onlyRole(APPRAISER_ROLE) {
        engines[engineId].currentAppraisedValue = FHE.fromExternal(encValue, proof);
        FHE.allowThis(engines[engineId].currentAppraisedValue);
        FHE.allow(engines[engineId].currentAppraisedValue, engines[engineId].lessor);
    }

    function negotiateLease(
        uint256 engineId,
        externalEuint64 encMonthlyRent,
        bytes calldata rentProof,
        externalEuint64 encMaintReserve,
        bytes calldata maintProof,
        externalEuint32 encCreditScore,
        bytes calldata creditProof,
        externalEuint64 encDeposit,
        bytes calldata depositProof,
        uint256 durationDays
    ) external onlyRole(LESSEE_ROLE) whenNotPaused returns (uint256 leaseId) {
        Engine storage e = engines[engineId];
        require(e.available, "Not available");
        leaseId = nextLeaseId++;

        leases[leaseId] = EngineLease({
            engineId: engineId,
            lessee: msg.sender,
            monthlyRent: FHE.fromExternal(encMonthlyRent, rentProof),
            maintenanceReserve: FHE.fromExternal(encMaintReserve, maintProof),
            creditScore: FHE.fromExternal(encCreditScore, creditProof),
            securityDeposit: FHE.fromExternal(encDeposit, depositProof),
            totalPaid: FHE.asEuint64(0),
            startDate: block.timestamp,
            endDate: block.timestamp + durationDays * 1 days,
            status: LeaseStatus.Negotiating
        });

        FHE.allowThis(leases[leaseId].monthlyRent);
        FHE.allow(leases[leaseId].monthlyRent, msg.sender);
        FHE.allow(leases[leaseId].monthlyRent, e.lessor);
        FHE.allowThis(leases[leaseId].creditScore);
        FHE.allow(leases[leaseId].creditScore, e.lessor);
        FHE.allowThis(leases[leaseId].securityDeposit);
        FHE.allowThis(leases[leaseId].totalPaid);
        FHE.allowThis(leases[leaseId].maintenanceReserve);

        e.available = false;
        lesseeLeases[msg.sender].push(leaseId);
        emit LeaseNegotiated(leaseId, engineId, msg.sender);
    }

    function activateLease(uint256 leaseId) external onlyRole(LESSOR_ROLE) {
        leases[leaseId].status = LeaseStatus.Active;
        emit LeaseActivated(leaseId);
    }

    function recordPayment(
        uint256 leaseId,
        externalEuint64 encPayment,
        bytes calldata proof
    ) external nonReentrant whenNotPaused {
        EngineLease storage l = leases[leaseId];
        require(l.lessee == msg.sender, "Not lessee");
        require(l.status == LeaseStatus.Active, "Not active");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        l.totalPaid = FHE.add(l.totalPaid, payment);
        FHE.allowThis(l.totalPaid);
        FHE.allow(l.totalPaid, msg.sender);
        emit PaymentRecorded(leaseId);
    }

    function terminateLease(uint256 leaseId) external onlyRole(LESSOR_ROLE) {
        EngineLease storage l = leases[leaseId];
        require(l.status == LeaseStatus.Active || l.status == LeaseStatus.Suspended, "Invalid state");
        l.status = LeaseStatus.Terminated;
        engines[l.engineId].available = true;
        emit LeaseTerminated(leaseId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
