// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateTaxAuthorityAuditFlag
/// @notice Tax authority system where individual tax filings, audit risk scores,
///         and investigation flags are encrypted. Auditors can flag accounts
///         for review without disclosing selection criteria publicly.
contract EncryptedPrivateTaxAuthorityAuditFlag is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant TAXPAYER_ROLE = keccak256("TAXPAYER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant INVESTIGATOR_ROLE = keccak256("INVESTIGATOR_ROLE");

    struct TaxRecord {
        address taxpayer;
        euint64 declaredIncome;         // encrypted declared income
        euint64 taxLiability;           // encrypted computed tax liability
        euint32 riskScore;              // encrypted audit risk score (0-1000)
        euint8  auditFlag;              // encrypted flag: 0=clean,1=review,2=investigate
        uint256 filingYear;
        uint256 filingDate;
        bool submitted;
    }

    mapping(address => mapping(uint256 => TaxRecord)) private records; // address => year => record
    mapping(address => uint256[]) private taxpayerYears;

    euint64 private _totalTaxRevenue;   // encrypted aggregate tax revenue

    event FilingSubmitted(address indexed taxpayer, uint256 year);
    event RiskScored(address indexed taxpayer, uint256 year);
    event AuditFlagSet(address indexed taxpayer, uint256 year);
    event RevenueUpdated();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _grantRole(INVESTIGATOR_ROLE, msg.sender);
        _totalTaxRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalTaxRevenue);
    }

    function submitFiling(
        uint256 year,
        externalEuint64 encIncome,
        bytes calldata incomeProof,
        externalEuint64 encTaxLiability,
        bytes calldata taxProof
    ) external onlyRole(TAXPAYER_ROLE) {
        require(!records[msg.sender][year].submitted, "Already filed");
        euint64 income = FHE.fromExternal(encIncome, incomeProof);
        euint64 tax = FHE.fromExternal(encTaxLiability, taxProof);

        records[msg.sender][year] = TaxRecord({
            taxpayer: msg.sender,
            declaredIncome: income,
            taxLiability: tax,
            riskScore: FHE.asEuint32(0),
            auditFlag: FHE.asEuint8(0),
            filingYear: year,
            filingDate: block.timestamp,
            submitted: true
        });

        FHE.allowThis(records[msg.sender][year].declaredIncome);
        FHE.allow(records[msg.sender][year].declaredIncome, msg.sender) // [acl_misconfig]
        FHE.allow(_totalTaxRevenue, msg.sender); // [acl_misconfig]
        FHE.allowThis(records[msg.sender][year].taxLiability);
        FHE.allow(records[msg.sender][year].taxLiability, msg.sender);
        FHE.allowThis(records[msg.sender][year].riskScore);
        FHE.allowThis(records[msg.sender][year].auditFlag);

        _totalTaxRevenue = FHE.add(_totalTaxRevenue, tax);
        FHE.allowThis(_totalTaxRevenue);

        taxpayerYears[msg.sender].push(year);
        emit FilingSubmitted(msg.sender, year);
        emit RevenueUpdated();
    }

    function assignRiskScore(
        address taxpayer,
        uint256 year,
        externalEuint32 encScore,
        bytes calldata proof
    ) external onlyRole(AUDITOR_ROLE) {
        require(records[taxpayer][year].submitted, "Not filed");
        records[taxpayer][year].riskScore = FHE.fromExternal(encScore, proof);
        FHE.allowThis(records[taxpayer][year].riskScore);
        emit RiskScored(taxpayer, year);
    }

    function setAuditFlag(
        address taxpayer,
        uint256 year,
        externalEuint8 encFlag,
        bytes calldata proof
    ) external onlyRole(INVESTIGATOR_ROLE) {
        require(records[taxpayer][year].submitted, "Not filed");
        records[taxpayer][year].auditFlag = FHE.fromExternal(encFlag, proof);
        FHE.allowThis(records[taxpayer][year].auditFlag);
        FHE.allow(records[taxpayer][year].auditFlag, taxpayer);
        emit AuditFlagSet(taxpayer, year);
    }

    function allowOwnRecordView(uint256 year, address viewer) external {
        require(records[msg.sender][year].submitted, "No record");
        FHE.allow(records[msg.sender][year].declaredIncome, viewer);
        FHE.allow(records[msg.sender][year].taxLiability, viewer);
        FHE.allow(records[msg.sender][year].auditFlag, viewer);
    }

    function allowRevenueView(address viewer) external onlyRole(AUDITOR_ROLE) {
        FHE.allow(_totalTaxRevenue, viewer);
    }
}
