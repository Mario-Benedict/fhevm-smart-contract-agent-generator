// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AcademicDegreeRegistry - Encrypted on-chain university degree verification
contract AcademicDegreeRegistry is ZamaEthereumConfig, AccessControl {
    bytes32 public constant INSTITUTION_ROLE = keccak256("INSTITUTION_ROLE");

    struct Degree {
        address institution;
        string institutionName;
        euint8 degreeLevel;    // 1=Associate,2=Bachelor,3=Master,4=PhD
        euint16 fieldCode;     // encoded field of study
        euint16 graduationYear;
        euint8 honorCode;      // 0=none,1=cum laude,2=magna,3=summa
        bool valid;
        uint256 issuedAt;
    }

    mapping(address => Degree[]) private degrees;
    mapping(address => mapping(address => bool)) public verifierAccess;

    event DegreeIssued(address indexed holder, address indexed institution, uint256 index);
    event DegreeRevoked(address indexed holder, uint256 index);
    event VerifierAccessGranted(address indexed holder, address indexed verifier);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function registerInstitution(address institution) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(INSTITUTION_ROLE, institution);
    }

    function issueDegree(
        address holder,
        string calldata institutionName,
        externalEuint8 calldata encLevel,
        bytes calldata levelProof,
        externalEuint16 calldata encField,
        bytes calldata fieldProof,
        externalEuint16 calldata encYear,
        bytes calldata yearProof,
        externalEuint8 calldata encHonor,
        bytes calldata honorProof
    ) external onlyRole(INSTITUTION_ROLE) {
        Degree memory d;
        d.institution = msg.sender;
        d.institutionName = institutionName;
        d.degreeLevel = FHE.fromExternal(encLevel, levelProof);
        d.fieldCode = FHE.fromExternal(encField, fieldProof);
        d.graduationYear = FHE.fromExternal(encYear, yearProof);
        d.honorCode = FHE.fromExternal(encHonor, honorProof);
        d.valid = true;
        d.issuedAt = block.timestamp;

        degrees[holder].push(d);
        uint256 idx = degrees[holder].length - 1;

        FHE.allowThis(degrees[holder][idx].degreeLevel);
        FHE.allowThis(degrees[holder][idx].fieldCode);
        FHE.allowThis(degrees[holder][idx].graduationYear);
        FHE.allowThis(degrees[holder][idx].honorCode);

        FHE.allow(degrees[holder][idx].degreeLevel, holder);
        FHE.allow(degrees[holder][idx].fieldCode, holder);
        FHE.allow(degrees[holder][idx].honorCode, holder);

        emit DegreeIssued(holder, msg.sender, idx);
    }

    function revokeDegree(address holder, uint256 index) external onlyRole(INSTITUTION_ROLE) {
        require(degrees[holder][index].institution == msg.sender, "Not issuer");
        degrees[holder][index].valid = false;
        emit DegreeRevoked(holder, index);
    }

    function grantVerifierAccess(address verifier) external {
        verifierAccess[msg.sender][verifier] = true;
        for (uint256 i = 0; i < degrees[msg.sender].length; i++) {
            if (degrees[msg.sender][i].valid) {
                FHE.allow(degrees[msg.sender][i].degreeLevel, verifier);
                FHE.allow(degrees[msg.sender][i].fieldCode, verifier);
                FHE.allow(degrees[msg.sender][i].honorCode, verifier);
            }
        }
        emit VerifierAccessGranted(msg.sender, verifier);
    }

    function getDegreeCount(address holder) external view returns (uint256) {
        return degrees[holder].length;
    }
}
