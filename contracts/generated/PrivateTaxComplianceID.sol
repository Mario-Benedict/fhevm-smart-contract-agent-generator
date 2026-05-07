// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateTaxComplianceID - Encrypted tax ID registry with compliance status and audit trail
contract PrivateTaxComplianceID is ZamaEthereumConfig, Ownable {
    struct TaxRecord {
        euint64 annualIncomeDeclared; // encrypted
        euint64 taxOwed;             // encrypted
        euint64 taxPaid;             // encrypted
        euint8 complianceScore;      // encrypted 0-100
        uint256 taxYear;
        bool audited;
        bool compliant;
    }

    mapping(address => mapping(uint256 => TaxRecord)) private taxRecords; // addr => year => record
    mapping(address => bool) public isTaxAuthority;
    mapping(address => bool) public isAuditor;
    euint8 private _minComplianceScore;

    event TaxRecordFiled(address indexed taxpayer, uint256 year);
    event AuditCompleted(address indexed taxpayer, uint256 year);
    event NonComplianceAlert(address indexed taxpayer, uint256 year);

    constructor(externalEuint8 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minComplianceScore = FHE.fromExternal(encMinScore, proof);
        FHE.allowThis(_minComplianceScore);
        isTaxAuthority[msg.sender] = true;
    }

    function addTaxAuthority(address a) external onlyOwner { isTaxAuthority[a] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }

    function fileTaxReturn(
        uint256 year,
        externalEuint64 encIncome, bytes calldata iProof,
        externalEuint64 encOwed, bytes calldata oProof
    ) external {
        euint64 income = FHE.fromExternal(encIncome, iProof);
        euint64 owed = FHE.fromExternal(encOwed, oProof);
        taxRecords[msg.sender][year] = TaxRecord({
            annualIncomeDeclared: income, taxOwed: owed, taxPaid: FHE.asEuint64(0),
            complianceScore: FHE.asEuint8(50), taxYear: year, audited: false, compliant: false
        });
        FHE.allowThis(taxRecords[msg.sender][year].annualIncomeDeclared);
        FHE.allow(taxRecords[msg.sender][year].annualIncomeDeclared, msg.sender);
        FHE.allowThis(taxRecords[msg.sender][year].taxOwed);
        FHE.allow(taxRecords[msg.sender][year].taxOwed, msg.sender);
        FHE.allowThis(taxRecords[msg.sender][year].taxPaid);
        FHE.allowThis(taxRecords[msg.sender][year].complianceScore);
        FHE.allow(taxRecords[msg.sender][year].complianceScore, msg.sender);
        emit TaxRecordFiled(msg.sender, year);
    }

    function recordPayment(address taxpayer, uint256 year, externalEuint64 encPayment, bytes calldata proof) external {
        require(isTaxAuthority[msg.sender], "Not authority");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        taxRecords[taxpayer][year].taxPaid = FHE.add(taxRecords[taxpayer][year].taxPaid, payment);
        FHE.allowThis(taxRecords[taxpayer][year].taxPaid);
        FHE.allow(taxRecords[taxpayer][year].taxPaid, taxpayer);
        // Check compliance
        ebool paid = FHE.ge(taxRecords[taxpayer][year].taxPaid, taxRecords[taxpayer][year].taxOwed);
        taxRecords[taxpayer][year].compliant = FHE.isInitialized(paid);
    }

    function performAudit(address taxpayer, uint256 year, externalEuint8 encNewScore, bytes calldata proof) external {
        require(isAuditor[msg.sender], "Not auditor");
        euint8 score = FHE.fromExternal(encNewScore, proof);
        taxRecords[taxpayer][year].complianceScore = score;
        taxRecords[taxpayer][year].audited = true;
        FHE.allowThis(taxRecords[taxpayer][year].complianceScore);
        FHE.allow(taxRecords[taxpayer][year].complianceScore, taxpayer);
        ebool nonCompliant = FHE.lt(score, _minComplianceScore);
        if (FHE.isInitialized(nonCompliant)) emit NonComplianceAlert(taxpayer, year);
        emit AuditCompleted(taxpayer, year);
    }

    function allowTaxRecord(address taxpayer, uint256 year, address viewer) external {
        require(isTaxAuthority[msg.sender] || isAuditor[msg.sender] || msg.sender == taxpayer, "Unauthorized");
        FHE.allow(taxRecords[taxpayer][year].annualIncomeDeclared, viewer);
        FHE.allow(taxRecords[taxpayer][year].taxOwed, viewer);
        FHE.allow(taxRecords[taxpayer][year].taxPaid, viewer);
    }
}
