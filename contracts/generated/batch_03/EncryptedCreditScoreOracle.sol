// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title EncryptedCreditScoreOracle - Encrypted FICO-style credit scores with range-proof attestations
contract EncryptedCreditScoreOracle is ZamaEthereumConfig, AccessControl {
    bytes32 public constant BUREAU_ROLE  = keccak256("BUREAU_ROLE");
    bytes32 public constant LENDER_ROLE  = keccak256("LENDER_ROLE");

    struct CreditProfile {
        euint16 score;               // 300–850
        euint8  paymentHistory;      // 0-100
        euint8  creditUtilization;   // 0-100
        euint8  creditAge;           // in years
        euint8  recentInquiries;
        uint256 lastUpdated;
        bool    exists;
    }

    struct ScoreAttestation {
        address lender;
        euint8  rangeCode;   // 1=<580, 2=580-669, 3=670-739, 4=740-799, 5=800+
        ebool   above700;    // threshold check without revealing score
        uint256 issuedAt;
        uint256 validUntil;
    }

    mapping(address => CreditProfile)    private profiles;
    mapping(address => ScoreAttestation[]) private attestations;
    mapping(address => mapping(address => bool)) public disclosurePermitted;

    event ProfileCreated(address indexed subject);
    event ProfileUpdated(address indexed subject, address indexed bureau);
    event AttestationIssued(address indexed subject, address indexed lender);
    event DisclosureGranted(address indexed subject, address indexed lender);
    event DisclosureRevoked(address indexed subject, address indexed lender);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BUREAU_ROLE, msg.sender);
    }

    function createProfile(
        address subject,
        externalEuint16 encScore,       bytes calldata scoreProof,
        externalEuint8 encPayHist,     bytes calldata payHistProof,
        externalEuint8 encUtilization, bytes calldata utilizationProof,
        externalEuint8 encAge,         bytes calldata ageProof,
        externalEuint8 encInquiries,   bytes calldata inquiriesProof
    ) external onlyRole(BUREAU_ROLE) {
        CreditProfile storage p = profiles[subject];
        p.score             = FHE.fromExternal(encScore,       scoreProof);
        p.paymentHistory    = FHE.fromExternal(encPayHist,     payHistProof);
        p.creditUtilization = FHE.fromExternal(encUtilization, utilizationProof);
        p.creditAge         = FHE.fromExternal(encAge,         ageProof);
        p.recentInquiries   = FHE.fromExternal(encInquiries,   inquiriesProof);
        p.lastUpdated       = block.timestamp;
        p.exists            = true;
        FHE.allowThis(p.score); FHE.allowThis(p.paymentHistory);
        FHE.allowThis(p.creditUtilization); FHE.allowThis(p.creditAge); FHE.allowThis(p.recentInquiries);
        FHE.allow(p.score, subject);
        emit ProfileCreated(subject);
    }

    function updateScore(address subject, externalEuint16 encScore, bytes calldata inputProof)
        external onlyRole(BUREAU_ROLE)
    {
        profiles[subject].score       = FHE.fromExternal(encScore, inputProof);
        profiles[subject].lastUpdated = block.timestamp;
        FHE.allowThis(profiles[subject].score);
        FHE.allow(profiles[subject].score, subject);
        emit ProfileUpdated(subject, msg.sender);
    }

    function grantDisclosure(address lender, uint256 validDays) external {
        disclosurePermitted[msg.sender][lender] = true;
        CreditProfile storage p = profiles[msg.sender];
        FHE.allow(p.score, lender);
        FHE.allow(p.paymentHistory, lender);
        FHE.allow(p.creditUtilization, lender);
        emit DisclosureGranted(msg.sender, lender);
    }

    function revokeDisclosure(address lender) external {
        disclosurePermitted[msg.sender][lender] = false;
        emit DisclosureRevoked(msg.sender, lender);
    }

    function issueAttestation(address subject, uint256 validDays) external onlyRole(LENDER_ROLE) {
        require(disclosurePermitted[subject][msg.sender], "No disclosure permission");
        CreditProfile storage p = profiles[subject];
        ebool above700 = FHE.ge(p.score, FHE.asEuint16(700));
        // compute range code from score
        euint8 rangeCode = FHE.select(
            FHE.ge(p.score, FHE.asEuint16(800)), FHE.asEuint8(5),
            FHE.select(FHE.ge(p.score, FHE.asEuint16(740)), FHE.asEuint8(4),
            FHE.select(FHE.ge(p.score, FHE.asEuint16(670)), FHE.asEuint8(3),
            FHE.select(FHE.ge(p.score, FHE.asEuint16(580)), FHE.asEuint8(2),
            FHE.asEuint8(1))))
        );
        attestations[subject].push(ScoreAttestation({
            lender: msg.sender, rangeCode: rangeCode, above700: above700,
            issuedAt: block.timestamp, validUntil: block.timestamp + validDays * 1 days
        }));
        uint256 idx = attestations[subject].length - 1;
        FHE.allowThis(attestations[subject][idx].rangeCode);
        FHE.allow(attestations[subject][idx].rangeCode, msg.sender);
        FHE.allow(attestations[subject][idx].rangeCode, subject);
        emit AttestationIssued(subject, msg.sender);
    }

    function getAttestationCount(address subject) external view returns (uint256) {
        return attestations[subject].length;
    }
}
