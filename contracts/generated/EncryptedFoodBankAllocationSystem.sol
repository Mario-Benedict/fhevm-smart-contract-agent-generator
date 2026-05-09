// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFoodBankAllocationSystem
/// @notice Food bank management where beneficiary need assessments, allocated
///         quantities, and donation amounts from corporate donors are encrypted.
///         Prevents stigma while enabling auditable fair distribution.
contract EncryptedFoodBankAllocationSystem is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant VOLUNTEER_ROLE = keccak256("VOLUNTEER_ROLE");
    bytes32 public constant DONOR_ROLE = keccak256("DONOR_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    struct Beneficiary {
        address wallet;
        euint32 needScore;          // encrypted need assessment score
        euint32 weeklyAllocation;   // encrypted allocated kg of food
        euint32 totalReceived;      // encrypted total kg received
        uint256 lastAllocationWeek;
        bool registered;
    }

    struct DonationRecord {
        address donor;
        euint64 amountKg;           // encrypted donation quantity
        uint256 donationDate;
        string category;            // "fresh", "canned", "dry", etc.
    }

    mapping(address => Beneficiary) private beneficiaries;
    mapping(uint256 => DonationRecord) private donations;
    uint256 public nextDonationId;

    euint64 private _totalInventoryKg;  // encrypted total stock
    euint64 private _totalDistributedKg; // encrypted total distributed

    event BeneficiaryRegistered(address indexed beneficiary);
    event NeedAssessed(address indexed beneficiary);
    event DonationReceived(uint256 indexed donationId, address donor, string category);
    event AllocationMade(address indexed beneficiary);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VOLUNTEER_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _totalInventoryKg = FHE.asEuint64(0);
        _totalDistributedKg = FHE.asEuint64(0);
        FHE.allowThis(_totalInventoryKg);
        FHE.allowThis(_totalDistributedKg);
    }

    function registerBeneficiary(address beneficiary) external onlyRole(VOLUNTEER_ROLE) {
        require(!beneficiaries[beneficiary].registered, "Already registered");
        beneficiaries[beneficiary] = Beneficiary({
            wallet: beneficiary,
            needScore: FHE.asEuint32(0),
            weeklyAllocation: FHE.asEuint32(0),
            totalReceived: FHE.asEuint32(0),
            lastAllocationWeek: 0,
            registered: true
        });
        FHE.allowThis(beneficiaries[beneficiary].needScore);
        FHE.allowThis(beneficiaries[beneficiary].weeklyAllocation);
        FHE.allow(beneficiaries[beneficiary].weeklyAllocation, beneficiary);
        FHE.allowThis(beneficiaries[beneficiary].totalReceived);
        FHE.allow(beneficiaries[beneficiary].totalReceived, beneficiary);
        emit BeneficiaryRegistered(beneficiary);
    }

    function assessNeed(
        address beneficiary,
        externalEuint32 encScore,
        bytes calldata scoreProof,
        externalEuint32 encWeeklyAlloc,
        bytes calldata allocProof
    ) external onlyRole(VOLUNTEER_ROLE) {
        require(beneficiaries[beneficiary].registered, "Not registered");
        beneficiaries[beneficiary].needScore = FHE.fromExternal(encScore, scoreProof);
        beneficiaries[beneficiary].weeklyAllocation = FHE.fromExternal(encWeeklyAlloc, allocProof);
        FHE.allowThis(beneficiaries[beneficiary].needScore);
        FHE.allowThis(beneficiaries[beneficiary].weeklyAllocation);
        FHE.allow(beneficiaries[beneficiary].weeklyAllocation, beneficiary);
        emit NeedAssessed(beneficiary);
    }

    function recordDonation(
        externalEuint64 encKg,
        bytes calldata proof,
        string calldata category
    ) external onlyRole(DONOR_ROLE) returns (uint256 id) {
        id = nextDonationId++;
        euint64 kg = FHE.fromExternal(encKg, proof);
        donations[id] = DonationRecord({
            donor: msg.sender,
            amountKg: kg,
            donationDate: block.timestamp,
            category: category
        });
        FHE.allowThis(donations[id].amountKg);
        FHE.allow(donations[id].amountKg, msg.sender);

        _totalInventoryKg = FHE.add(_totalInventoryKg, kg);
        FHE.allowThis(_totalInventoryKg);
        emit DonationReceived(id, msg.sender, category);
    }

    function distributeAllocation(address beneficiary) external onlyRole(VOLUNTEER_ROLE) nonReentrant {
        Beneficiary storage b = beneficiaries[beneficiary];
        require(b.registered, "Not registered");
        uint256 currentWeek = block.timestamp / 7 days;
        require(currentWeek > b.lastAllocationWeek, "Already allocated this week");

        euint32 alloc = b.weeklyAllocation;
        euint64 alloc64 = FHE.asEuint64(alloc);

        // Ensure inventory sufficient
        ebool hasStock = FHE.ge(_totalInventoryKg, alloc64);
        euint64 actualAlloc = FHE.select(hasStock, alloc64, _totalInventoryKg);

        _totalInventoryKg = FHE.sub(_totalInventoryKg, actualAlloc);
        _totalDistributedKg = FHE.add(_totalDistributedKg, actualAlloc);
        b.totalReceived = FHE.add(b.totalReceived, FHE.asEuint32(actualAlloc));

        FHE.allowThis(_totalInventoryKg);
        FHE.allowThis(_totalDistributedKg);
        FHE.allowThis(b.totalReceived);
        FHE.allow(b.totalReceived, beneficiary);

        b.lastAllocationWeek = currentWeek;
        emit AllocationMade(beneficiary);
    }

    function allowAuditView(address auditor) external onlyRole(AUDITOR_ROLE) {
        FHE.allow(_totalInventoryKg, auditor);
        FHE.allow(_totalDistributedKg, auditor);
    }
}
