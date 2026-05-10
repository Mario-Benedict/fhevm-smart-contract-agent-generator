// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedAcademicDegree - University degree registry with encrypted GPA, encrypted honors, and selective sharing
contract EncryptedAcademicDegree is ZamaEthereumConfig, Ownable {
    struct Degree {
        string institution;
        string fieldOfStudy;
        euint16 gpaX100;     // encrypted GPA * 100 (e.g. 380 = 3.80)
        euint8 honorsLevel;  // encrypted 0=none,1=cum laude,2=magna,3=summa
        uint256 graduationYear;
        bool verified;
        address issuer;
    }

    mapping(address => Degree[]) private degrees;
    mapping(address => bool) public isUniversity;
    mapping(address => mapping(address => bool)) public sharingConsent;

    event DegreeIssued(address indexed graduate, uint256 index, string institution);
    event DegreeVerified(address indexed graduate, uint256 index);
    event ConsentGranted(address indexed graduate, address employer);

    constructor() Ownable(msg.sender) {
        isUniversity[msg.sender] = true;
    }

    function addUniversity(address u) external onlyOwner { isUniversity[u] = true; }

    function issueDegree(
        address graduate,
        string calldata institution,
        string calldata field,
        externalEuint16 encGPA, bytes calldata gProof,
        externalEuint8 encHonors, bytes calldata hProof,
        uint256 gradYear
    ) external {
        require(isUniversity[msg.sender], "Not university");
        euint16 gpa = FHE.fromExternal(encGPA, gProof);
        euint8 honors = FHE.fromExternal(encHonors, hProof);
        uint256 idx = degrees[graduate].length;
        degrees[graduate].push(Degree({
            institution: institution, fieldOfStudy: field, gpaX100: gpa, honorsLevel: honors,
            graduationYear: gradYear, verified: true, issuer: msg.sender
        }));
        FHE.allowThis(degrees[graduate][idx].gpaX100);
        FHE.allow(degrees[graduate][idx].gpaX100, graduate);
        FHE.allowThis(degrees[graduate][idx].honorsLevel);
        FHE.allow(degrees[graduate][idx].honorsLevel, graduate);
        emit DegreeIssued(graduate, idx, institution);
    }

    function grantEmployerConsent(address employer) external {
        sharingConsent[msg.sender][employer] = true;
        for (uint256 i = 0; i < degrees[msg.sender].length; i++) {
            FHE.allow(degrees[msg.sender][i].gpaX100, employer);
            FHE.allow(degrees[msg.sender][i].honorsLevel, employer);
        }
        emit ConsentGranted(msg.sender, employer);
    }

    function revokeConsent(address employer) external { sharingConsent[msg.sender][employer] = false; }

    function getDegreeCount(address graduate) external view returns (uint256) {
        return degrees[graduate].length;
    }

    function isDegreeVerified(address graduate, uint256 index) external view returns (bool) {
        return degrees[graduate][index].verified;
    }

    function allowDegreeDetails(address graduate, uint256 index, address viewer) external {
        require(isUniversity[msg.sender] || msg.sender == graduate || sharingConsent[graduate][msg.sender], "Unauthorized");
        FHE.allow(degrees[graduate][index].gpaX100, viewer);
        FHE.allow(degrees[graduate][index].honorsLevel, viewer);
    }
}
