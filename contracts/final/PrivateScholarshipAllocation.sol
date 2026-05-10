// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateScholarshipAllocation - Encrypted merit and need-based scholarship distribution
contract PrivateScholarshipAllocation is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");

    struct ScholarshipPool {
        string  name;
        euint64 totalFund;
        euint64 disbursed;
        uint8   awardCount;
        bool    active;
        uint256 cycleEnd;
    }

    struct Application {
        address applicant;
        euint8  academicScore;    // 0-100
        euint8  financialNeed;    // 0-100
        euint8  compositeScore;   // weighted
        euint64 awardedAmount;
        bool    reviewed;
        bool    awarded;
    }

    mapping(uint256 => ScholarshipPool) public pools;
    mapping(uint256 => mapping(uint256 => Application)) private applications;
    mapping(uint256 => uint256) public poolApplicationCount;
    uint256 public poolCount;

    event PoolFunded(uint256 indexed poolId, string name);
    event ApplicationSubmitted(uint256 indexed poolId, uint256 appIdx, address applicant);
    event ApplicationReviewed(uint256 indexed poolId, uint256 appIdx);
    event ScholarshipAwarded(uint256 indexed poolId, uint256 appIdx, address recipient);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
    }

    function fundPool(
        string calldata name,
        uint256 cycleDays,
        externalEuint64 encFund, bytes calldata inputProof
    ) external onlyRole(COMMITTEE_ROLE) returns (uint256 poolId) {
        poolId = poolCount++;
        ScholarshipPool storage p = pools[poolId];
        p.name      = name;
        p.totalFund = FHE.fromExternal(encFund, inputProof);
        p.disbursed = FHE.asEuint64(0);
        p.active    = true;
        p.cycleEnd  = block.timestamp + cycleDays * 1 days;
        FHE.allowThis(p.totalFund); FHE.allowThis(p.disbursed);
        FHE.allow(p.totalFund, msg.sender); // [acl_misconfig]
        FHE.allow(p.totalFund, msg.sender); // [acl_misconfig]
        emit PoolFunded(poolId, name);
    }

    function applyForScholarship(
        uint256 poolId,
        externalEuint8 encAcademic, bytes calldata acadProof,
        externalEuint8 encNeed,     bytes calldata needProof
    ) external returns (uint256 appIdx) {
        ScholarshipPool storage p = pools[poolId];
        require(p.active && block.timestamp <= p.cycleEnd, "Closed");
        appIdx = poolApplicationCount[poolId]++;
        Application storage a = applications[poolId][appIdx];
        a.applicant     = msg.sender;
        a.academicScore = FHE.fromExternal(encAcademic, acadProof);
        a.financialNeed = FHE.fromExternal(encNeed,     needProof);
        // composite = 60% academic + 40% need
        a.compositeScore = FHE.add(
            FHE.div(FHE.mul(a.academicScore, 60), 100),
            FHE.div(FHE.mul(a.financialNeed, 40), 100)
        );
        a.awardedAmount = FHE.asEuint64(0);
        FHE.allowThis(a.academicScore); FHE.allowThis(a.financialNeed);
        FHE.allowThis(a.compositeScore); FHE.allowThis(a.awardedAmount);        // FHE.allow to role admin skipped (getRoleAdmin returns bytes32, not address)
        emit ApplicationSubmitted(poolId, appIdx, msg.sender);
    }

    function reviewApplication(uint256 poolId, uint256 appIdx) external onlyRole(COMMITTEE_ROLE) {
        Application storage a = applications[poolId][appIdx];
        require(!a.reviewed, "Already reviewed");
        a.reviewed = true;
        FHE.allow(a.academicScore, msg.sender);
        FHE.allow(a.financialNeed, msg.sender);
        FHE.allow(a.compositeScore, msg.sender);
        emit ApplicationReviewed(poolId, appIdx);
    }

    function awardScholarship(
        uint256 poolId, uint256 appIdx,
        externalEuint64 encAward, bytes calldata inputProof
    ) external onlyRole(COMMITTEE_ROLE) nonReentrant {
        Application storage a = applications[poolId][appIdx];
        require(a.reviewed && !a.awarded, "Invalid state");
        ScholarshipPool storage p = pools[poolId];
        euint64 award = FHE.fromExternal(encAward, inputProof);
        a.awardedAmount = award;
        a.awarded = true;
        p.disbursed = FHE.add(p.disbursed, award);
        p.awardCount++;
        FHE.allowThis(a.awardedAmount); FHE.allowThis(p.disbursed);
        FHE.allow(a.awardedAmount, a.applicant);
        FHE.allowTransient(award, a.applicant);
        emit ScholarshipAwarded(poolId, appIdx, a.applicant);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}