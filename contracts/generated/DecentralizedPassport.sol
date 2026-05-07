// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DecentralizedPassport - Self-sovereign identity with encrypted biometric hashes and travel history
contract DecentralizedPassport is ZamaEthereumConfig, Ownable {
    struct Passport {
        euint256 biometricHash;        // encrypted biometric fingerprint
        euint32 nationalityCode;
        euint8 securityClearance;      // 1-5 encrypted
        uint256 issuedAt;
        uint256 expiryDate;
        bool valid;
        address issuingAuthority;
    }

    struct TravelRecord {
        euint32 destinationCountry;
        uint256 entryDate;
        bool exited;
    }

    mapping(address => Passport) private passports;
    mapping(address => TravelRecord[]) private travelHistory;
    mapping(address => bool) public isImmigrationAuthority;
    uint256 public totalPassports;

    event PassportIssued(address indexed holder);
    event PassportRevoked(address indexed holder);
    event TravelRecorded(address indexed holder, uint256 recordId);

    modifier onlyAuthority() {
        require(isImmigrationAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        isImmigrationAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isImmigrationAuthority[a] = true; }

    function issuePassport(
        address holder,
        externalEuint256 encBiometric, bytes calldata bProof,
        externalEuint32 encNationality, bytes calldata nProof,
        externalEuint8 encClearance, bytes calldata cProof,
        uint256 validityYears
    ) external onlyAuthority {
        euint256 biometric = FHE.fromExternal(encBiometric, bProof);
        euint32 nationality = FHE.fromExternal(encNationality, nProof);
        euint8 clearance = FHE.fromExternal(encClearance, cProof);
        passports[holder] = Passport({
            biometricHash: biometric, nationalityCode: nationality, securityClearance: clearance,
            issuedAt: block.timestamp, expiryDate: block.timestamp + validityYears * 365 days,
            valid: true, issuingAuthority: msg.sender
        });
        FHE.allowThis(passports[holder].biometricHash);
        FHE.allow(passports[holder].biometricHash, holder);
        FHE.allowThis(passports[holder].nationalityCode);
        FHE.allow(passports[holder].nationalityCode, holder);
        FHE.allowThis(passports[holder].securityClearance);
        FHE.allow(passports[holder].securityClearance, holder);
        totalPassports++;
        emit PassportIssued(holder);
    }

    function revokePassport(address holder) external onlyAuthority {
        passports[holder].valid = false;
        emit PassportRevoked(holder);
    }

    function recordTravel(
        address holder,
        externalEuint32 encDestination, bytes calldata proof
    ) external onlyAuthority {
        require(passports[holder].valid, "Invalid passport");
        euint32 dest = FHE.fromExternal(encDestination, proof);
        uint256 recordId = travelHistory[holder].length;
        travelHistory[holder].push(TravelRecord({ destinationCountry: dest, entryDate: block.timestamp, exited: false }));
        FHE.allowThis(travelHistory[holder][recordId].destinationCountry);
        FHE.allow(travelHistory[holder][recordId].destinationCountry, holder);
        emit TravelRecorded(holder, recordId);
    }

    function recordExit(address holder, uint256 recordId) external onlyAuthority {
        travelHistory[holder][recordId].exited = true;
    }

    function verifyPassport(address holder) external view returns (bool) {
        return passports[holder].valid && block.timestamp < passports[holder].expiryDate;
    }

    function allowPassportDetails(address holder, address viewer) external {
        require(msg.sender == holder || isImmigrationAuthority[msg.sender], "Unauthorized");
        FHE.allow(passports[holder].biometricHash, viewer);
        FHE.allow(passports[holder].nationalityCode, viewer);
        FHE.allow(passports[holder].securityClearance, viewer);
    }
}
