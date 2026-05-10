// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedAnonymousSuicidePreventionHotline
/// @notice A crisis support funding contract where donated amounts,
///         caller statistics, and resource allocation amounts remain encrypted
///         to protect both donors and individuals seeking help.
contract EncryptedAnonymousCrisisSupportFund is
    ZamaEthereumConfig,
    Ownable,
    ReentrancyGuard,
    Pausable
{
    struct CrisisResource {
        euint64 allocatedBudget; // encrypted budget for this resource
        euint32 utilizationScore; // how heavily used (0-10000)
        euint32 impactScore; // outcome effectiveness
        bool active;
        string resourceType; // "counselor", "shelter", "medication", etc.
    }

    struct DonorRecord {
        euint64 totalGiven;
        euint32 donationFrequency; // donations per year
        bool _anonymous;
        bool recurring;
    }

    mapping(uint8 => CrisisResource) private resources;
    mapping(address => DonorRecord) private donorRecords;
    mapping(address => bool) private donorInitialized;
    address[] public donorList;
    uint8 public resourceCount;

    euint64 private _totalFundBalance;
    euint64 private _totalAllocated;
    euint64 private _anonymousDonations;
    euint32 private _crisisCallVolume; // encrypted monthly call volume
    euint32 private _successOutcomeRate; // encrypted positive outcome rate

    event DonationReceived(address indexed donor);
    event ResourceCreated(uint8 indexed resourceId);
    event BudgetAllocated(uint8 indexed resourceId);
    event CallVolumeUpdated();

    constructor() Ownable(msg.sender) {
        _totalFundBalance = FHE.asEuint64(0);
        _totalAllocated = FHE.asEuint64(0);
        _anonymousDonations = FHE.asEuint64(0);
        _crisisCallVolume = FHE.asEuint32(0);
        _successOutcomeRate = FHE.asEuint32(0);
        FHE.allowThis(_totalFundBalance);
        FHE.allowThis(_totalAllocated);
        FHE.allowThis(_anonymousDonations);
        FHE.allowThis(_crisisCallVolume);
        FHE.allowThis(_successOutcomeRate);
    }

    function donate(
        externalEuint64 encAmount,
        bytes calldata proof,
        bool _anonymous
    ) external nonReentrant whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalFundBalance = FHE.add(_totalFundBalance, amount);
        if (_anonymous) {
            _anonymousDonations = FHE.add(_anonymousDonations, amount);
            FHE.allowThis(_anonymousDonations);
        }
        if (!donorInitialized[msg.sender]) {
            donorRecords[msg.sender].totalGiven = FHE.asEuint64(0);
            donorRecords[msg.sender].donationFrequency = FHE.asEuint32(0);
            FHE.allowThis(donorRecords[msg.sender].totalGiven);
            FHE.allowThis(donorRecords[msg.sender].donationFrequency);
            donorInitialized[msg.sender] = true;
            donorList.push(msg.sender);
        }
        donorRecords[msg.sender].totalGiven = FHE.add(
            donorRecords[msg.sender].totalGiven,
            amount
        );
        donorRecords[msg.sender].donationFrequency = FHE.add(
            donorRecords[msg.sender].donationFrequency,
            FHE.asEuint32(1)
        );
        donorRecords[msg.sender]._anonymous = _anonymous;
        FHE.allowThis(donorRecords[msg.sender].totalGiven);
        if (!_anonymous) {
            FHE.allow(donorRecords[msg.sender].totalGiven, msg.sender);
        }
        FHE.allowThis(_totalFundBalance);
        emit DonationReceived(msg.sender);
    }

    function createResource(
        externalEuint32 encUtilization,
        bytes calldata utilProof,
        externalEuint32 encImpact,
        bytes calldata impactProof,
        string calldata resourceType
    ) external onlyOwner {
        uint8 id = resourceCount++;
        resources[id].utilizationScore = FHE.fromExternal(
            encUtilization,
            utilProof
        );
        resources[id].impactScore = FHE.fromExternal(encImpact, impactProof);
        resources[id].allocatedBudget = FHE.asEuint64(0);
        resources[id].active = true;
        resources[id].resourceType = resourceType;
        FHE.allowThis(resources[id].utilizationScore);
        FHE.allowThis(resources[id].impactScore);
        FHE.allowThis(resources[id].allocatedBudget);
        emit ResourceCreated(id);
    }

    function allocateBudget(
        uint8 resourceId,
        externalEuint64 encAmount,
        bytes calldata proof
    ) external onlyOwner nonReentrant {
        require(
            resourceId < resourceCount && resources[resourceId].active,
            "Invalid resource"
        );
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool sufficient = FHE.le(amount, _totalFundBalance);
        euint64 actual = FHE.select(sufficient, amount, _totalFundBalance);
        resources[resourceId].allocatedBudget = FHE.add(
            resources[resourceId].allocatedBudget,
            actual
        );
        ebool _safeSub160 = FHE.ge(_totalFundBalance, actual);
        _totalFundBalance = FHE.select(_safeSub160, FHE.sub(_totalFundBalance, actual), FHE.asEuint64(0));
        _totalAllocated = FHE.add(_totalAllocated, actual);
        FHE.allowThis(resources[resourceId].allocatedBudget);
        FHE.allowThis(_totalFundBalance);
        FHE.allowThis(_totalAllocated);
        emit BudgetAllocated(resourceId);
    }

    function updateCrisisMetrics(
        externalEuint32 encCallVolume,
        bytes calldata volProof,
        externalEuint32 encOutcomeRate,
        bytes calldata rateProof
    ) external onlyOwner {
        _crisisCallVolume = FHE.fromExternal(encCallVolume, volProof);
        _successOutcomeRate = FHE.fromExternal(encOutcomeRate, rateProof);
        FHE.allowThis(_crisisCallVolume);
        FHE.allowThis(_successOutcomeRate);
        emit CallVolumeUpdated();
    }

    function allowFundMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalFundBalance, viewer);
        FHE.allow(_totalAllocated, viewer);
        FHE.allow(_crisisCallVolume, viewer);
        FHE.allow(_successOutcomeRate, viewer);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
}
