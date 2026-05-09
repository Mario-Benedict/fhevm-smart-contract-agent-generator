// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EducationPrivateCredential
/// @notice Academic credential system with encrypted GPA, course scores, and
///         degree completion status. Employers verify academic qualifications
///         without seeing full transcript details.
contract EducationPrivateCredential is ZamaEthereumConfig, Ownable {
    enum DegreeLevel { Associate, Bachelor, Master, Doctorate }

    struct AcademicRecord {
        string institution;
        string major;
        DegreeLevel degree;
        euint16 gpaHundredths;         // GPA * 100 (encrypted): 400 = 4.00
        euint8 graduationYear;         // years since 2000 (encrypted)
        euint8 creditsCompleted;
        euint8 honorsCode;             // 0=none, 1=cum laude, 2=magna, 3=summa
        bool verified;
        address institution_address;
    }

    struct CourseGrade {
        string courseCode;
        euint8 gradePoints;   // 0-40 (encrypted): 40=A+
        euint8 creditHours;
        uint256 semester;
    }

    mapping(address => AcademicRecord[]) private credentials;
    mapping(address => CourseGrade[]) private transcripts;
    mapping(address => bool) public isInstitution;
    mapping(address => mapping(address => bool)) public studentConsent; // student => employer => consent

    event CredentialIssued(address indexed student, address institution, DegreeLevel level);
    event CourseGradeRecorded(address indexed student, string courseCode);
    event ConsentGranted(address indexed student, address employer);

    constructor() Ownable(msg.sender) {}

    function registerInstitution(address inst) external onlyOwner { isInstitution[inst] = true; }

    function grantConsent(address employer) external {
        studentConsent[msg.sender][employer] = true;
        emit ConsentGranted(msg.sender, employer);
    }

    function issueCredential(
        address student, string calldata major,
        DegreeLevel degree,
        externalEuint16 encGPA, bytes calldata gProof,
        externalEuint8 encGradYear, bytes calldata yProof,
        externalEuint8 encCredits, bytes calldata cProof,
        externalEuint8 encHonors, bytes calldata hProof
    ) external {
        require(isInstitution[msg.sender], "Not institution");
        credentials[student].push(AcademicRecord({
            institution: "University",
            major: major,
            degree: degree,
            gpaHundredths: FHE.fromExternal(encGPA, gProof),
            graduationYear: FHE.fromExternal(encGradYear, yProof),
            creditsCompleted: FHE.fromExternal(encCredits, cProof),
            honorsCode: FHE.fromExternal(encHonors, hProof),
            verified: true,
            institution_address: msg.sender
        }));
        uint256 idx = credentials[student].length - 1;
        FHE.allowThis(credentials[student][idx].gpaHundredths);
        FHE.allow(credentials[student][idx].gpaHundredths, student);
        FHE.allowThis(credentials[student][idx].graduationYear);
        FHE.allow(credentials[student][idx].graduationYear, student);
        FHE.allowThis(credentials[student][idx].creditsCompleted);
        FHE.allow(credentials[student][idx].creditsCompleted, student);
        FHE.allowThis(credentials[student][idx].honorsCode);
        FHE.allow(credentials[student][idx].honorsCode, student);
        emit CredentialIssued(student, msg.sender, degree);
    }

    function recordGrade(
        address student, string calldata courseCode, uint256 semester,
        externalEuint8 encGradePoints, bytes calldata gProof,
        externalEuint8 encCredits, bytes calldata cProof
    ) external {
        require(isInstitution[msg.sender], "Not institution");
        transcripts[student].push(CourseGrade({
            courseCode: courseCode,
            gradePoints: FHE.fromExternal(encGradePoints, gProof),
            creditHours: FHE.fromExternal(encCredits, cProof),
            semester: semester
        }));
        uint256 idx = transcripts[student].length - 1;
        FHE.allowThis(transcripts[student][idx].gradePoints);
        FHE.allow(transcripts[student][idx].gradePoints, student);
        FHE.allowThis(transcripts[student][idx].creditHours);
        FHE.allow(transcripts[student][idx].creditHours, student);
        emit CourseGradeRecorded(student, courseCode);
    }

    function verifyMinimumGPA(
        address student, uint256 credentialIndex,
        externalEuint16 encMinGPA, bytes calldata proof
    ) external returns (bool) {
        require(studentConsent[student][msg.sender], "No consent");
        require(credentialIndex < credentials[student].length, "Invalid");
        euint16 minGPA = FHE.fromExternal(encMinGPA, proof);
        ebool qualifies = FHE.ge(credentials[student][credentialIndex].gpaHundredths, minGPA);
        return FHE.isInitialized(qualifies);
    }

    function grantTranscriptAccess(address viewer, uint256 credentialIndex) external {
        FHE.allow(credentials[msg.sender][credentialIndex].gpaHundredths, viewer);
        FHE.allow(credentials[msg.sender][credentialIndex].honorsCode, viewer);
    }
}
