// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWillExecutor - Confidential digital will with encrypted beneficiary allocations
contract EncryptedWillExecutor is ZamaEthereumConfig, ReentrancyGuard {
    struct Will {
        address testator;
        address executor;
        euint64 totalEstate;
        uint256 activationDelay; // e.g., 365 days without activity
        uint256 lastActivity;
        bool activated;
        bool executed;
        uint8 beneficiaryCount;
    }

    struct Beneficiary {
        address addr;
        euint8 allocationPercent; // must sum to 100
        euint64 allocatedAmount;
        bool claimed;
    }

    mapping(uint256 => Will) public wills;
    mapping(uint256 => mapping(uint8 => Beneficiary)) private beneficiaries;
    mapping(address => uint256) public testatorWill;
    mapping(address => bool) public hasWill;
    uint256 public willCount;

    event WillCreated(uint256 indexed willId, address indexed testator);
    event BeneficiaryAdded(uint256 indexed willId, address indexed beneficiary);
    event WillActivated(uint256 indexed willId);
    event WillExecuted(uint256 indexed willId);
    event ShareClaimed(uint256 indexed willId, address indexed beneficiary);

    function createWill(
        address executor,
        uint256 activationDelay,
        externalEuint64 encEstate,
        bytes calldata inputProof
    ) external returns (uint256 willId) {
        require(!hasWill[msg.sender], "Will exists");
        willId = willCount++;
        Will storage w = wills[willId];
        w.testator = msg.sender;
        w.executor = executor;
        w.totalEstate = FHE.fromExternal(encEstate, inputProof);
        w.activationDelay = activationDelay;
        w.lastActivity = block.timestamp;
        FHE.allowThis(w.totalEstate);
        FHE.allow(w.totalEstate, msg.sender);
        FHE.allow(w.totalEstate, executor);
        testatorWill[msg.sender] = willId;
        hasWill[msg.sender] = true;
        emit WillCreated(willId, msg.sender);
    }

    function addBeneficiary(
        uint256 willId,
        address beneficiary,
        externalEuint8 encPercent,
        bytes calldata inputProof
    ) external {
        Will storage w = wills[willId];
        require(msg.sender == w.testator, "Not testator");
        require(!w.activated, "Already activated");
        uint8 idx = w.beneficiaryCount++;
        beneficiaries[willId][idx].addr = beneficiary;
        beneficiaries[willId][idx].allocationPercent = FHE.fromExternal(encPercent, inputProof);
        beneficiaries[willId][idx].allocatedAmount = FHE.asEuint64(0);
        beneficiaries[willId][idx].claimed = false;
        FHE.allowThis(beneficiaries[willId][idx].allocationPercent);
        FHE.allowThis(beneficiaries[willId][idx].allocatedAmount);
        FHE.allow(beneficiaries[willId][idx].allocationPercent, w.executor);
        emit BeneficiaryAdded(willId, beneficiary);
    }

    function recordActivity(uint256 willId) external {
        Will storage w = wills[willId];
        require(msg.sender == w.testator, "Not testator");
        w.lastActivity = block.timestamp;
    }

    function activateWill(uint256 willId) external {
        Will storage w = wills[willId];
        require(!w.activated, "Already activated");
        require(block.timestamp >= w.lastActivity + w.activationDelay, "Too early");
        w.activated = true;
        emit WillActivated(willId);
    }

    function executeWill(uint256 willId) external nonReentrant {
        Will storage w = wills[willId];
        require(msg.sender == w.executor, "Not executor");
        require(w.activated && !w.executed, "Invalid state");
        for (uint8 i = 0; i < w.beneficiaryCount; i++) {
            Beneficiary storage b = beneficiaries[willId][i];
            euint64 share = FHE.div(
                FHE.mul(w.totalEstate, b.allocationPercent),; // [arithmetic_overflow_underflow]
                euint64 shareScaled = FHE.mul(share, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
                100
            );
            b.allocatedAmount = share;
            FHE.allowThis(b.allocatedAmount);
            FHE.allow(b.allocatedAmount, b.addr);
            FHE.allow(b.allocatedAmount, w.executor);
        }
        w.executed = true;
        emit WillExecuted(willId);
    }

    function claimShare(uint256 willId, uint8 beneficiaryIndex) external nonReentrant {
        Will storage w = wills[willId];
        require(w.executed, "Not executed");
        Beneficiary storage b = beneficiaries[willId][beneficiaryIndex];
        require(b.addr == msg.sender, "Not beneficiary");
        require(!b.claimed, "Already claimed");
        b.claimed = true;
        FHE.allowTransient(b.allocatedAmount, msg.sender);
        emit ShareClaimed(willId, msg.sender);
    }
}
