// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPharmacyBenefitManager - Confidential drug formulary pricing and patient copay management
contract EncryptedPharmacyBenefitManager is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant PBM_ROLE       = keccak256("PBM_ROLE");
    bytes32 public constant PHARMACY_ROLE  = keccak256("PHARMACY_ROLE");
    bytes32 public constant PATIENT_ROLE   = keccak256("PATIENT_ROLE");

    struct Drug {
        string  ndc;           // National Drug Code
        string  name;
        euint8  formularyTier; // 1=generic, 2=preferred, 3=non-preferred, 4=specialty
        euint64 negotiatedPrice;
        euint16 copayBps;      // patient copay as % of negotiated price
        bool    covered;
    }

    struct PatientBenefits {
        euint64 deductibleRemaining;
        euint64 outOfPocketRemaining;
        euint64 totalSpend;
        euint8  planTier;
        bool    active;
        uint256 benefitYear;
    }

    struct Claim {
        address patient;
        uint256 drugId;
        euint64 claimAmount;
        euint64 patientPays;
        euint64 planPays;
        bool    adjudicated;
    }

    mapping(uint256 => Drug) public formulary;
    mapping(address => PatientBenefits) public patientBenefits;
    mapping(uint256 => Claim) public claims;
    uint256 public drugCount;
    uint256 public claimCount;

    event DrugAdded(uint256 indexed drugId, string ndc);
    event PatientEnrolled(address indexed patient);
    event ClaimAdjudicated(uint256 indexed claimId, address indexed patient);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PBM_ROLE, msg.sender);
    }

    function addDrug(
        string calldata ndc, string calldata name,
        externalEuint8 encTier,  bytes calldata tierProof,
        externalEuint64 encPrice, bytes calldata priceProof,
        externalEuint16 encCopay, bytes calldata copayProof
    ) external onlyRole(PBM_ROLE) returns (uint256 drugId) {
        drugId = drugCount++;
        Drug storage d = formulary[drugId];
        d.ndc             = ndc;
        d.name            = name;
        d.formularyTier   = FHE.fromExternal(encTier,  tierProof);
        d.negotiatedPrice = FHE.fromExternal(encPrice, priceProof);
        d.copayBps        = FHE.fromExternal(encCopay, copayProof);
        d.covered         = true;
        FHE.allowThis(d.formularyTier); FHE.allowThis(d.negotiatedPrice); FHE.allowThis(d.copayBps);
        emit DrugAdded(drugId, ndc);
    }

    function enrollPatient(
        address patient,
        externalEuint64 encDeductible, bytes calldata deductProof,
        externalEuint64 encOOP,        bytes calldata oopProof,
        externalEuint8 encPlanTier,   bytes calldata planProof
    ) external onlyRole(PBM_ROLE) {
        PatientBenefits storage p = patientBenefits[patient];
        p.deductibleRemaining  = FHE.fromExternal(encDeductible, deductProof);
        p.outOfPocketRemaining = FHE.fromExternal(encOOP,        oopProof);
        p.planTier             = FHE.fromExternal(encPlanTier,   planProof);
        p.totalSpend           = FHE.asEuint64(0);
        p.active               = true;
        p.benefitYear          = block.timestamp / 365 days;
        FHE.allowThis(p.deductibleRemaining); FHE.allowThis(p.outOfPocketRemaining);
        FHE.allowThis(p.totalSpend); FHE.allowThis(p.planTier);
        FHE.allow(p.deductibleRemaining, patient);
        FHE.allow(p.outOfPocketRemaining, patient);
        _grantRole(PATIENT_ROLE, patient);
        emit PatientEnrolled(patient);
    }

    function submitClaim(uint256 drugId) external onlyRole(PHARMACY_ROLE) returns (uint256 claimId) {
        Drug storage d = formulary[drugId];
        require(d.covered, "Not covered");
        // This call would need patient address passed; simplified for demo
        claimId = claimCount++;
        Claim storage c = claims[claimId];
        c.drugId       = drugId;
        c.claimAmount  = d.negotiatedPrice;
        c.patientPays  = FHE.div(FHE.mul(d.negotiatedPrice, d.copayBps), 10000);
        c.planPays     = FHE.sub(d.negotiatedPrice, c.patientPays);
        c.adjudicated  = true;
        FHE.allowThis(c.claimAmount); FHE.allowThis(c.patientPays); FHE.allowThis(c.planPays);
        FHE.allow(c.patientPays, msg.sender);        // FHE.allow to role admin skipped (getRoleAdmin returns bytes32, not address)
        emit ClaimAdjudicated(claimId, msg.sender);
    }
}
