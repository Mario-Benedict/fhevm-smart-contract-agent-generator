// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedHospitalBillingAdjudicator
/// @notice Hospital billing system where claim amounts, insurance negotiations,
///         and final patient obligations are encrypted. Insurers adjudicate
///         without revealing negotiated rates to competing payers.
contract EncryptedHospitalBillingAdjudicator is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant HOSPITAL_ROLE = keccak256("HOSPITAL_ROLE");
    bytes32 public constant INSURER_ROLE = keccak256("INSURER_ROLE");
    bytes32 public constant PATIENT_ROLE = keccak256("PATIENT_ROLE");

    enum ClaimStatus { Submitted, UnderReview, Approved, PartiallyApproved, Denied, Paid }

    struct Claim {
        address patient;
        address hospital;
        address insurer;
        euint64 billedAmount;       // encrypted gross billed
        euint64 negotiatedRate;     // encrypted insurer's negotiated rate
        euint64 patientObligation;  // encrypted patient responsibility
        euint64 insurerObligation;  // encrypted insurer responsibility
        uint256 serviceDate;
        ClaimStatus status;
        string diagnosis;           // ICD-10 code (public, for audit)
    }

    uint256 public nextClaimId;
    mapping(uint256 => Claim) private claims;
    mapping(address => uint256[]) private patientClaims;
    mapping(address => uint256[]) private hospitalClaims;

    event ClaimSubmitted(uint256 indexed claimId, address patient, string diagnosis);
    event ClaimAdjudicated(uint256 indexed claimId, ClaimStatus status);
    event ClaimPaid(uint256 indexed claimId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function submitClaim(
        address patient,
        address insurer,
        externalEuint64 encBilled,
        bytes calldata billedProof,
        uint256 serviceDate,
        string calldata diagnosis
    ) external onlyRole(HOSPITAL_ROLE) returns (uint256 claimId) {
        claimId = nextClaimId++;
        euint64 billed = FHE.fromExternal(encBilled, billedProof);

        claims[claimId] = Claim({
            patient: patient,
            hospital: msg.sender,
            insurer: insurer,
            billedAmount: billed,
            negotiatedRate: FHE.asEuint64(0),
            patientObligation: FHE.asEuint64(0),
            insurerObligation: FHE.asEuint64(0),
            serviceDate: serviceDate,
            status: ClaimStatus.Submitted,
            diagnosis: diagnosis
        });

        FHE.allowThis(claims[claimId].billedAmount);
        FHE.allow(claims[claimId].billedAmount, insurer);
        FHE.allowThis(claims[claimId].negotiatedRate);
        FHE.allowThis(claims[claimId].patientObligation);
        FHE.allowThis(claims[claimId].insurerObligation);

        patientClaims[patient].push(claimId);
        hospitalClaims[msg.sender].push(claimId);
        emit ClaimSubmitted(claimId, patient, diagnosis);
    }

    function adjudicateClaim(
        uint256 claimId,
        externalEuint64 encNegotiated,
        bytes calldata negProof,
        externalEuint64 encPatientShare,
        bytes calldata patientProof,
        bool approved
    ) external onlyRole(INSURER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.insurer == msg.sender, "Wrong insurer");
        require(c.status == ClaimStatus.Submitted || c.status == ClaimStatus.UnderReview, "Invalid state");

        euint64 negotiated = FHE.fromExternal(encNegotiated, negProof);
        euint64 patientShare = FHE.fromExternal(encPatientShare, patientProof);

        c.negotiatedRate = negotiated;
        c.patientObligation = patientShare;
        c.insurerObligation = FHE.sub(negotiated, patientShare);

        FHE.allowThis(c.negotiatedRate);
        FHE.allowThis(c.patientObligation);
        FHE.allow(c.patientObligation, c.patient);
        FHE.allowThis(c.insurerObligation);
        FHE.allow(c.insurerObligation, c.hospital);

        c.status = approved ? ClaimStatus.Approved : ClaimStatus.Denied;
        emit ClaimAdjudicated(claimId, c.status);
    }

    function markPaid(uint256 claimId) external onlyRole(INSURER_ROLE) {
        Claim storage c = claims[claimId];
        require(c.insurer == msg.sender, "Wrong insurer");
        require(c.status == ClaimStatus.Approved || c.status == ClaimStatus.PartiallyApproved, "Not approved");
        c.status = ClaimStatus.Paid;
        emit ClaimPaid(claimId);
    }

    function allowPatientView(uint256 claimId, address viewer) external {
        Claim storage c = claims[claimId];
        require(msg.sender == c.patient, "Not patient");
        FHE.allow(c.patientObligation, viewer);
    }

    function getPatientClaims(address patient) external view returns (uint256[] memory) {
        return patientClaims[patient];
    }
}
