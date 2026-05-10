// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title PrivateCarbonFootprintTracker - Confidential corporate GHG emission reporting and offset matching
contract PrivateCarbonFootprintTracker is ZamaEthereumConfig, AccessControl {
    bytes32 public constant AUDITOR_ROLE  = keccak256("AUDITOR_ROLE");
    bytes32 public constant COMPANY_ROLE  = keccak256("COMPANY_ROLE");

    struct EmissionRecord {
        euint64 scope1Tonnes;   // direct emissions
        euint64 scope2Tonnes;   // indirect energy
        euint64 scope3Tonnes;   // value chain
        euint64 offsetsPurchased;
        euint32 reportingYear;
        bool audited;
        address auditor;
    }

    struct OffsetCertificate {
        address issuer;
        euint64 tonnesCO2;
        string projectId;
        uint256 issuedAt;
        bool retired;
    }

    mapping(address => EmissionRecord[]) private companyRecords;
    mapping(uint256 => OffsetCertificate) public offsets;
    mapping(address => euint64) public netEmissions;
    uint256 public offsetCount;

    event EmissionReported(address indexed company, uint256 recordIndex);
    event EmissionAudited(address indexed company, uint256 recordIndex, address indexed auditor);
    event OffsetIssued(uint256 indexed offsetId, address indexed company);
    event OffsetRetired(uint256 indexed offsetId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    function registerCompany(address company) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(COMPANY_ROLE, company);
        netEmissions[company] = FHE.asEuint64(0);
        FHE.allowThis(netEmissions[company]);
        FHE.allow(netEmissions[company], company);
    }

    function reportEmissions(
        externalEuint64 encS1, bytes calldata s1Proof,
        externalEuint64 encS2, bytes calldata s2Proof,
        externalEuint64 encS3, bytes calldata s3Proof,
        externalEuint32 encYear, bytes calldata yearProof
    ) external onlyRole(COMPANY_ROLE) returns (uint256 idx) {
        EmissionRecord memory r;
        r.scope1Tonnes = FHE.fromExternal(encS1, s1Proof);
        r.scope2Tonnes = FHE.fromExternal(encS2, s2Proof);
        r.scope3Tonnes = FHE.fromExternal(encS3, s3Proof);
        r.offsetsPurchased = FHE.asEuint64(0);
        r.reportingYear = FHE.fromExternal(encYear, yearProof);
        companyRecords[msg.sender].push(r);
        idx = companyRecords[msg.sender].length - 1;
        FHE.allowThis(companyRecords[msg.sender][idx].scope1Tonnes);
        FHE.allowThis(companyRecords[msg.sender][idx].scope2Tonnes);
        FHE.allowThis(companyRecords[msg.sender][idx].scope3Tonnes);
        FHE.allowThis(companyRecords[msg.sender][idx].offsetsPurchased);
        FHE.allowThis(companyRecords[msg.sender][idx].reportingYear);
        FHE.allow(companyRecords[msg.sender][idx].scope1Tonnes, msg.sender);

        euint64 total = FHE.add(FHE.add(r.scope1Tonnes, r.scope2Tonnes), r.scope3Tonnes);
        netEmissions[msg.sender] = FHE.add(netEmissions[msg.sender], total);
        FHE.allowThis(netEmissions[msg.sender]);
        FHE.allow(netEmissions[msg.sender], msg.sender);
        emit EmissionReported(msg.sender, idx);
    }

    function auditRecord(address company, uint256 recordIndex) external onlyRole(AUDITOR_ROLE) {
        EmissionRecord storage r = companyRecords[company][recordIndex];
        require(!r.audited, "Already audited");
        r.audited = true;
        r.auditor = msg.sender;
        FHE.allow(companyRecords[company][recordIndex].scope1Tonnes, msg.sender);
        FHE.allow(companyRecords[company][recordIndex].scope2Tonnes, msg.sender);
        FHE.allow(companyRecords[company][recordIndex].scope3Tonnes, msg.sender);
        emit EmissionAudited(company, recordIndex, msg.sender);
    }

    function issueOffset(
        address company,
        string calldata projectId,
        externalEuint64 encTonnes, bytes calldata inputProof
    ) external onlyRole(AUDITOR_ROLE) returns (uint256 offsetId) {
        offsetId = offsetCount++;
        OffsetCertificate storage o = offsets[offsetId];
        o.issuer    = msg.sender;
        o.tonnesCO2 = FHE.fromExternal(encTonnes, inputProof);
        o.projectId = projectId;
        o.issuedAt  = block.timestamp;
        FHE.allowThis(o.tonnesCO2);
        FHE.allow(o.tonnesCO2, company);
        netEmissions[company] = FHE.sub(netEmissions[company], o.tonnesCO2);
        FHE.allowThis(netEmissions[company]);
        FHE.allow(netEmissions[company], company);
        emit OffsetIssued(offsetId, company);
    }

    function retireOffset(uint256 offsetId) external onlyRole(AUDITOR_ROLE) {
        offsets[offsetId].retired = true;
        emit OffsetRetired(offsetId);
    }

    function getRecordCount(address company) external view returns (uint256) {
        return companyRecords[company].length;
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