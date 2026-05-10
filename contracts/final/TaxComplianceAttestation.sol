// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title TaxComplianceAttestation - Encrypted tax filing status and income bracket attestation
contract TaxComplianceAttestation is ZamaEthereumConfig, Ownable {
    struct TaxRecord {
        euint8 incomeBracket;    // 1-7 bracket code
        euint8 filingStatus;     // 0=single, 1=married, 2=head of household
        euint16 taxYear;
        euint8 complianceScore;  // 0-100
        euint8 auditRiskFlag;    // 0=low, 1=medium, 2=high
        bool attested;
        uint256 attestedAt;
    }

    mapping(address => TaxRecord) public records;
    mapping(address => mapping(address => bool)) public disclosureConsent;
    mapping(address => bool) public authorizedAttestors;

    event TaxRecordAttested(address indexed taxpayer, uint16 taxYear);
    event DisclosureConsented(address indexed taxpayer, address indexed recipient);

    constructor() Ownable(msg.sender) {}

    function authorizeAttestor(address attestor) external onlyOwner {
        authorizedAttestors[attestor] = true;
    }

    function attestTaxRecord(
        address taxpayer,
        externalEuint8 encBracket,
        bytes calldata bracketProof,
        externalEuint8 encFiling,
        bytes calldata filingProof,
        externalEuint16 encYear,
        bytes calldata yearProof,
        externalEuint8 encScore,
        bytes calldata scoreProof,
        externalEuint8 encAudit,
        bytes calldata auditProof
    ) external {
        require(authorizedAttestors[msg.sender], "Not authorized");
        TaxRecord storage r = records[taxpayer];
        r.incomeBracket = FHE.fromExternal(encBracket, bracketProof);
        r.filingStatus = FHE.fromExternal(encFiling, filingProof);
        r.taxYear = FHE.fromExternal(encYear, yearProof);
        r.complianceScore = FHE.fromExternal(encScore, scoreProof);
        r.auditRiskFlag = FHE.fromExternal(encAudit, auditProof);
        r.attested = true;
        r.attestedAt = block.timestamp;

        FHE.allowThis(r.incomeBracket);
        FHE.allowThis(r.filingStatus);
        FHE.allowThis(r.taxYear);
        FHE.allowThis(r.complianceScore);
        euint8 _scaledScore = FHE.mul(r.complianceScore, FHE.asEuint8(10)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(r.auditRiskFlag);

        FHE.allow(r.incomeBracket, taxpayer); // [acl_misconfig]
        FHE.allow(r.incomeBracket, msg.sender); // [acl_misconfig]

        FHE.allow(r.complianceScore, taxpayer);
        FHE.allow(r.auditRiskFlag, taxpayer);

        emit TaxRecordAttested(taxpayer, 0);
    }

    function consentDisclosure(address recipient) external {
        disclosureConsent[msg.sender][recipient] = true;
        TaxRecord storage r = records[msg.sender];
        if (r.attested) {
            FHE.allow(r.incomeBracket, recipient);
            FHE.allow(r.complianceScore, recipient);
            FHE.allow(r.filingStatus, recipient);
        }
        emit DisclosureConsented(msg.sender, recipient);
    }

    function revokeConsent(address recipient) external {
        disclosureConsent[msg.sender][recipient] = false;
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