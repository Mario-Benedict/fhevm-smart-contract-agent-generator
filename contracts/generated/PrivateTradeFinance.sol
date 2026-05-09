// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTradeFinance - Encrypted letter of credit and trade finance instrument
contract PrivateTradeFinance is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");
    bytes32 public constant EXPORTER_ROLE = keccak256("EXPORTER_ROLE");
    bytes32 public constant IMPORTER_ROLE = keccak256("IMPORTER_ROLE");
    bytes32 public constant INSPECTOR_ROLE = keccak256("INSPECTOR_ROLE");

    enum LCStatus { Issued, Presented, Inspected, Settled, Rejected }

    struct LetterOfCredit {
        address issuingBank;
        address importer;
        address exporter;
        euint64 creditAmount;
        euint64 settledAmount;
        euint8 inspectionScore;
        LCStatus status;
        uint256 expiryDate;
        string goodsDescription;
        string documentHash;
    }

    mapping(uint256 => LetterOfCredit) public letters;
    uint256 public lcCount;

    event LCIssued(uint256 indexed lcId, address indexed importer, address indexed exporter);
    event DocumentPresented(uint256 indexed lcId, address indexed exporter);
    event InspectionRecorded(uint256 indexed lcId, uint8 score);
    event LCSettled(uint256 indexed lcId);
    event LCRejected(uint256 indexed lcId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BANK_ROLE, msg.sender);
    }

    function issueLC(
        address importer,
        address exporter,
        externalEuint64 encAmount,
        bytes calldata amountProof,
        uint256 validDays,
        string calldata goodsDescription
    ) external onlyRole(BANK_ROLE) returns (uint256 lcId) {
        lcId = lcCount++;
        LetterOfCredit storage lc = letters[lcId];
        lc.issuingBank = msg.sender;
        lc.importer = importer;
        lc.exporter = exporter;
        lc.creditAmount = FHE.fromExternal(encAmount, amountProof);
        lc.settledAmount = FHE.asEuint64(0);
        lc.inspectionScore = FHE.asEuint8(0);
        lc.status = LCStatus.Issued;
        lc.expiryDate = block.timestamp + validDays * 1 days;
        lc.goodsDescription = goodsDescription;
        FHE.allowThis(lc.creditAmount);
        FHE.allowThis(lc.settledAmount);
        FHE.allowThis(lc.inspectionScore);
        FHE.allow(lc.creditAmount, importer);
        FHE.allow(lc.creditAmount, exporter);
        FHE.allow(lc.creditAmount, msg.sender);
        emit LCIssued(lcId, importer, exporter);
    }

    function presentDocuments(uint256 lcId, string calldata documentHash) external onlyRole(EXPORTER_ROLE) {
        LetterOfCredit storage lc = letters[lcId];
        require(lc.exporter == msg.sender, "Not exporter");
        require(lc.status == LCStatus.Issued, "Invalid status");
        require(block.timestamp <= lc.expiryDate, "Expired");
        lc.documentHash = documentHash;
        lc.status = LCStatus.Presented;
        emit DocumentPresented(lcId, msg.sender);
    }

    function recordInspection(uint256 lcId, externalEuint8 encScore, bytes calldata inputProof)
        external
        onlyRole(INSPECTOR_ROLE)
    {
        LetterOfCredit storage lc = letters[lcId];
        require(lc.status == LCStatus.Presented, "Not presented");
        lc.inspectionScore = FHE.fromExternal(encScore, inputProof);
        lc.status = LCStatus.Inspected;
        FHE.allowThis(lc.inspectionScore);
        FHE.allow(lc.inspectionScore, lc.issuingBank);
        FHE.allow(lc.inspectionScore, lc.importer);
        emit InspectionRecorded(lcId, 0);
    }

    function settleLC(uint256 lcId, externalEuint64 encSettlement, bytes calldata inputProof)
        external
        onlyRole(BANK_ROLE)
        nonReentrant
    {
        LetterOfCredit storage lc = letters[lcId];
        require(lc.issuingBank == msg.sender, "Not issuing bank");
        require(lc.status == LCStatus.Inspected, "Not inspected");
        // qualityOk stored for ACL; caller (bank) verifies quality off-chain before settling
        ebool qualityOk = FHE.ge(lc.inspectionScore, FHE.asEuint8(60));
        FHE.allowThis(qualityOk);
        FHE.allow(qualityOk, msg.sender);
        lc.settledAmount = FHE.fromExternal(encSettlement, inputProof);
        lc.status = LCStatus.Settled;
        FHE.allowThis(lc.settledAmount);
        FHE.allow(lc.settledAmount, lc.exporter);
        FHE.allowTransient(lc.settledAmount, lc.exporter);
        emit LCSettled(lcId);
    }

    function rejectLC(uint256 lcId) external onlyRole(BANK_ROLE) {
        LetterOfCredit storage lc = letters[lcId];
        require(lc.issuingBank == msg.sender, "Not issuing bank");
        lc.status = LCStatus.Rejected;
        emit LCRejected(lcId);
    }
}
