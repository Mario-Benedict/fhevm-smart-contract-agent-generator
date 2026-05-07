// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWillExecution - Private digital will: encrypted beneficiary shares, triggered on death certificate
contract EncryptedWillExecution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Will {
        address testator;
        euint64 totalEstate;        // encrypted total estate value
        bool executed;
        bool activated;
        uint256 createdAt;
        address deathVerifier;
    }

    struct Beneficiary {
        address addr;
        euint8 sharePct;     // encrypted percentage 0-100
        euint64 shareAmount; // encrypted computed amount
        bool distributed;
    }

    mapping(uint256 => Will) private wills;
    mapping(uint256 => Beneficiary[]) private beneficiaries;
    mapping(address => uint256[]) private testatorWills;
    mapping(address => bool) public isDeathVerifier;
    uint256 public willCount;

    event WillCreated(uint256 indexed willId, address testator);
    event BeneficiaryAdded(uint256 indexed willId, address beneficiary);
    event WillActivated(uint256 indexed willId);
    event WillExecuted(uint256 indexed willId);
    event ShareDistributed(uint256 indexed willId, address beneficiary);

    constructor() Ownable(msg.sender) {
        isDeathVerifier[msg.sender] = true;
    }

    function addDeathVerifier(address v) external onlyOwner { isDeathVerifier[v] = true; }

    function createWill(externalEuint64 encEstate, bytes calldata proof, address verifier) external returns (uint256 willId) {
        euint64 estate = FHE.fromExternal(encEstate, proof);
        willId = willCount++;
        wills[willId] = Will({ testator: msg.sender, totalEstate: estate, executed: false,
            activated: false, createdAt: block.timestamp, deathVerifier: verifier });
        FHE.allowThis(wills[willId].totalEstate);
        FHE.allow(wills[willId].totalEstate, msg.sender);
        testatorWills[msg.sender].push(willId);
        emit WillCreated(willId, msg.sender);
    }

    function addBeneficiary(uint256 willId, address beneficiary, externalEuint8 encShare, bytes calldata proof) external {
        require(wills[willId].testator == msg.sender && !wills[willId].activated, "Cannot modify");
        euint8 share = FHE.fromExternal(encShare, proof);
        uint256 idx = beneficiaries[willId].length;
        beneficiaries[willId].push(Beneficiary({ addr: beneficiary, sharePct: share,
            shareAmount: FHE.asEuint64(0), distributed: false }));
        FHE.allowThis(beneficiaries[willId][idx].sharePct);
        FHE.allow(beneficiaries[willId][idx].sharePct, msg.sender); // testator sees shares
        FHE.allowThis(beneficiaries[willId][idx].shareAmount);
        emit BeneficiaryAdded(willId, beneficiary);
    }

    function activateWill(uint256 willId) external {
        require(isDeathVerifier[msg.sender] || msg.sender == wills[willId].deathVerifier, "Not verifier");
        require(!wills[willId].activated, "Already activated");
        wills[willId].activated = true;
        Will storage w = wills[willId];
        // Compute share amounts for each beneficiary
        for (uint256 i = 0; i < beneficiaries[willId].length; i++) {
            Beneficiary storage b = beneficiaries[willId][i];
            b.shareAmount = FHE.div(
                FHE.mul(w.totalEstate, FHE.asEuint64(uint64(0))),
                100
            );
            FHE.allowThis(b.shareAmount);
            FHE.allow(b.shareAmount, b.addr);
        }
        emit WillActivated(willId);
    }

    function distributeShare(uint256 willId, uint256 beneficiaryIndex) external nonReentrant {
        Will storage w = wills[willId];
        require(w.activated && !w.executed, "Invalid state");
        Beneficiary storage b = beneficiaries[willId][beneficiaryIndex];
        require(!b.distributed, "Already distributed");
        b.distributed = true;
        FHE.allow(b.shareAmount, b.addr);
        emit ShareDistributed(willId, b.addr);
    }

    function markExecuted(uint256 willId) external {
        require(isDeathVerifier[msg.sender], "Not verifier");
        wills[willId].executed = true;
        emit WillExecuted(willId);
    }

    function allowWillDetails(uint256 willId, address viewer) external {
        require(wills[willId].testator == msg.sender || isDeathVerifier[msg.sender], "Unauthorized");
        FHE.allow(wills[willId].totalEstate, viewer);
    }
}
