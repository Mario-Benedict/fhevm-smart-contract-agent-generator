// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateMedicalLicense - Healthcare professional license registry with encrypted specializations and sanctions
contract PrivateMedicalLicense is ZamaEthereumConfig, Ownable {
    enum LicenseStatus { Pending, Active, Suspended, Revoked }

    struct MedicalLicense {
        euint32 specializationCode;  // encrypted medical specialty code
        euint8 sanctionLevel;        // encrypted 0=none, 1=warning, 2=suspension, 3=revoked
        euint16 continualEduHours;   // encrypted CME credits
        uint256 issuedAt;
        uint256 expiryDate;
        LicenseStatus status;
        address licensingBoard;
    }

    mapping(address => MedicalLicense) private licenses;
    mapping(address => bool) public isLicensingBoard;
    mapping(address => bool) public isHospital;
    uint256 public totalLicensed;

    event LicenseIssued(address indexed practitioner);
    event LicenseSuspended(address indexed practitioner);
    event LicenseRevoked(address indexed practitioner);
    event CMECreditAdded(address indexed practitioner);

    modifier onlyBoard() {
        require(isLicensingBoard[msg.sender] || msg.sender == owner(), "Not board");
        _;
    }

    constructor() Ownable(msg.sender) {
        isLicensingBoard[msg.sender] = true;
    }

    function addBoard(address b) external onlyOwner { isLicensingBoard[b] = true; }
    function addHospital(address h) external onlyOwner { isHospital[h] = true; }

    function issueLicense(
        address practitioner,
        externalEuint32 encSpec, bytes calldata sProof,
        externalEuint8 encSanction, bytes calldata sanProof,
        uint256 validityYears
    ) external onlyBoard {
        euint32 spec = FHE.fromExternal(encSpec, sProof);
        euint64 specWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 specExposure = FHE.sub(specWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint8 sanction = FHE.fromExternal(encSanction, sanProof);
        licenses[practitioner] = MedicalLicense({
            specializationCode: spec, sanctionLevel: sanction, continualEduHours: FHE.asEuint16(0),
            issuedAt: block.timestamp, expiryDate: block.timestamp + validityYears * 365 days,
            status: LicenseStatus.Active, licensingBoard: msg.sender
        });
        FHE.allowThis(licenses[practitioner].specializationCode);
        FHE.allow(licenses[practitioner].specializationCode, practitioner); // [acl_misconfig]
        FHE.allow(licenses[practitioner].specializationCode, msg.sender); // [acl_misconfig]
        FHE.allowThis(licenses[practitioner].sanctionLevel);
        FHE.allow(licenses[practitioner].sanctionLevel, practitioner);
        FHE.allowThis(licenses[practitioner].continualEduHours);
        FHE.allow(licenses[practitioner].continualEduHours, practitioner);
        totalLicensed++;
        emit LicenseIssued(practitioner);
    }

    function addCMECredits(address practitioner, externalEuint16 encHours, bytes calldata proof) external onlyBoard {
        euint16 hr = FHE.fromExternal(encHours, proof);
        licenses[practitioner].continualEduHours = FHE.add(licenses[practitioner].continualEduHours, hr);
        FHE.allowThis(licenses[practitioner].continualEduHours);
        FHE.allow(licenses[practitioner].continualEduHours, practitioner);
        emit CMECreditAdded(practitioner);
    }

    function suspend(address practitioner) external onlyBoard {
        licenses[practitioner].status = LicenseStatus.Suspended;
        emit LicenseSuspended(practitioner);
    }

    function revoke(address practitioner) external onlyBoard {
        licenses[practitioner].status = LicenseStatus.Revoked;
        emit LicenseRevoked(practitioner);
    }

    function verifyLicense(address practitioner) external view returns (bool) {
        MedicalLicense storage lic = licenses[practitioner];
        return lic.status == LicenseStatus.Active && block.timestamp < lic.expiryDate;
    }

    function allowLicenseDetails(address practitioner, address viewer) external {
        require(isLicensingBoard[msg.sender] || isHospital[msg.sender] || msg.sender == practitioner, "Unauthorized");
        FHE.allow(licenses[practitioner].specializationCode, viewer);
        FHE.allow(licenses[practitioner].sanctionLevel, viewer);
        FHE.allow(licenses[practitioner].continualEduHours, viewer);
    }
}
