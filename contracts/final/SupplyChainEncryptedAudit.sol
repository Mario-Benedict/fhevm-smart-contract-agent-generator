// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SupplyChainEncryptedAudit
/// @notice Supply chain audit trail with encrypted ESG scores and supplier ratings.
///         Auditors record encrypted compliance scores; buyers can verify supplier
///         quality without revealing exact scores to competitors.
contract SupplyChainEncryptedAudit is ZamaEthereumConfig, Ownable {
    struct SupplierProfile {
        string companyName;
        euint8 environmentalScore;  // 0-100
        euint8 socialScore;
        euint8 governanceScore;
        euint8 overallESGScore;
        euint8 qualityScore;
        euint64 annualRevenue;      // encrypted
        bool registered;
        uint256 lastAuditDate;
    }

    struct AuditReport {
        address supplier;
        address auditor;
        euint8 complianceScore;
        euint8 riskRating;       // 1=low, 2=medium, 3=high, 4=critical
        string findings;
        uint256 auditDate;
        bool remediated;
    }

    mapping(address => SupplierProfile) private suppliers;
    address[] public supplierList;
    mapping(uint256 => AuditReport) private audits;
    uint256 public auditCount;
    mapping(address => bool) public isAuditor;
    mapping(address => bool) public isBuyer;
    mapping(address => mapping(address => bool)) public buyerAccess; // supplier => buyer => allowed

    event SupplierRegistered(address indexed supplier);
    event AuditCompleted(uint256 indexed auditId, address supplier, address auditor);
    event AccessGranted(address indexed supplier, address buyer);

    constructor() Ownable(msg.sender) {}

    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }
    function addBuyer(address b) external onlyOwner { isBuyer[b] = true; }

    function registerSupplier(
        string calldata companyName,
        externalEuint64 encRevenue, bytes calldata proof
    ) external {
        require(!suppliers[msg.sender].registered, "Already registered");
        suppliers[msg.sender].companyName = companyName;
        suppliers[msg.sender].annualRevenue = FHE.fromExternal(encRevenue, proof);
        suppliers[msg.sender].environmentalScore = FHE.asEuint8(0);
        suppliers[msg.sender].socialScore = FHE.asEuint8(0);
        suppliers[msg.sender].governanceScore = FHE.asEuint8(0);
        suppliers[msg.sender].overallESGScore = FHE.asEuint8(0);
        suppliers[msg.sender].qualityScore = FHE.asEuint8(0);
        suppliers[msg.sender].registered = true;
        FHE.allowThis(suppliers[msg.sender].annualRevenue);
        FHE.allow(suppliers[msg.sender].annualRevenue, msg.sender);
        FHE.allowThis(suppliers[msg.sender].environmentalScore);
        FHE.allowThis(suppliers[msg.sender].socialScore);
        FHE.allowThis(suppliers[msg.sender].governanceScore);
        FHE.allowThis(suppliers[msg.sender].overallESGScore);
        FHE.allowThis(suppliers[msg.sender].qualityScore);
        supplierList.push(msg.sender);
        emit SupplierRegistered(msg.sender);
    }

    function grantBuyerAccess(address buyer) external {
        require(suppliers[msg.sender].registered, "Not supplier");
        require(isBuyer[buyer], "Not buyer");
        buyerAccess[msg.sender][buyer] = true;
        FHE.allow(suppliers[msg.sender].environmentalScore, buyer);
        FHE.allow(suppliers[msg.sender].socialScore, buyer);
        FHE.allow(suppliers[msg.sender].governanceScore, buyer);
        FHE.allow(suppliers[msg.sender].overallESGScore, buyer);
        FHE.allow(suppliers[msg.sender].qualityScore, buyer);
        emit AccessGranted(msg.sender, buyer);
    }

    function conductAudit(
        address supplier, string calldata findings,
        externalEuint8 encEnv, bytes calldata eProof,
        externalEuint8 encSocial, bytes calldata sProof,
        externalEuint8 encGov, bytes calldata gProof,
        externalEuint8 encQuality, bytes calldata qProof,
        externalEuint8 encRisk, bytes calldata rProof
    ) external returns (uint256 id) {
        require(isAuditor[msg.sender], "Not auditor");
        require(suppliers[supplier].registered, "Not supplier");
        SupplierProfile storage sp = suppliers[supplier];
        sp.environmentalScore = FHE.fromExternal(encEnv, eProof);
        sp.socialScore = FHE.fromExternal(encSocial, sProof);
        sp.governanceScore = FHE.fromExternal(encGov, gProof);
        sp.qualityScore = FHE.fromExternal(encQuality, qProof);
        sp.overallESGScore = FHE.div(
            FHE.add(FHE.add(sp.environmentalScore, sp.socialScore), sp.governanceScore),
            3
        );
        sp.lastAuditDate = block.timestamp;
        FHE.allowThis(sp.environmentalScore);
        FHE.allow(sp.environmentalScore, supplier);
        FHE.allowThis(sp.socialScore);
        FHE.allow(sp.socialScore, supplier);
        FHE.allowThis(sp.governanceScore);
        FHE.allow(sp.governanceScore, supplier);
        FHE.allowThis(sp.qualityScore);
        FHE.allow(sp.qualityScore, supplier);
        FHE.allowThis(sp.overallESGScore);
        FHE.allow(sp.overallESGScore, supplier);
        id = auditCount++;
        euint8 risk = FHE.fromExternal(encRisk, rProof);
        euint64 riskWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 riskExposure = FHE.sub(riskWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        audits[id] = AuditReport({
            supplier: supplier, auditor: msg.sender,
            complianceScore: sp.overallESGScore, riskRating: risk,
            findings: findings, auditDate: block.timestamp, remediated: false
        });
        FHE.allowThis(audits[id].complianceScore);
        FHE.allow(audits[id].complianceScore, supplier);
        FHE.allowThis(audits[id].riskRating);
        FHE.allow(audits[id].riskRating, supplier);
        emit AuditCompleted(id, supplier, msg.sender);
    }

    function markRemediated(uint256 auditId) external onlyOwner {
        audits[auditId].remediated = true;
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