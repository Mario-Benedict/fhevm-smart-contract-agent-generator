// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ShieldedCredentials is ZamaEthereumConfig, Ownable {
    struct ProfessionalProfile {
        euint32 totalEncryptedScore;
        euint32 endorsementCount;
        bool isRegistered;
    }

    mapping(address => ProfessionalProfile) private profiles;
    mapping(address => mapping(address => bool)) private hasEndorsed;
    mapping(address => uint32) private _endorsementCountPlain; // plaintext shadow for division

    event ProfileCreated(address indexed professional);
    event EndorsementAdded(address indexed professional, address indexed endorser);

    constructor() Ownable(msg.sender) {}

    function createProfile() external {
        require(!profiles[msg.sender].isRegistered, "Already registered");

        euint32 initialScore = FHE.asEuint32(0);
        euint32 initialCount = FHE.asEuint32(0);
        FHE.allowThis(initialScore);
        FHE.allowThis(initialCount);

        profiles[msg.sender] = ProfessionalProfile({
            totalEncryptedScore: initialScore,
            endorsementCount: initialCount,
            isRegistered: true
        });

        emit ProfileCreated(msg.sender);
    }

    // An employer adds an encrypted performance score (e.g., 1 to 100)
    function addEncryptedEndorsement(
        address professional,
        externalEuint32 extScore,
        bytes calldata proof
    ) external {
        require(profiles[professional].isRegistered, "Profile not found");
        require(!hasEndorsed[professional][msg.sender], "Already endorsed");

        euint32 score = FHE.fromExternal(extScore, proof);
        FHE.allowThis(score);

        // Add to total score
        profiles[professional].totalEncryptedScore = FHE.add(profiles[professional].totalEncryptedScore, score);
        FHE.allowThis(profiles[professional].totalEncryptedScore);

        // Increment count
        profiles[professional].endorsementCount = FHE.add(profiles[professional].endorsementCount, FHE.asEuint32(1));
        _endorsementCountPlain[professional] += 1;
        FHE.allowThis(profiles[professional].endorsementCount);

        hasEndorsed[professional][msg.sender] = true;
        emit EndorsementAdded(professional, msg.sender);
    }

    // The professional grants temporary read access to a specific recruiter
    function grantAccessToRecruiter(address recruiter) external {
        require(profiles[msg.sender].isRegistered, "No profile");
        
        // Calculate average score opaquely
        uint32 countPlain = _endorsementCountPlain[msg.sender];
        euint32 averageScore = countPlain > 0 ? FHE.div(profiles[msg.sender].totalEncryptedScore, countPlain) : FHE.asEuint32(0);
        FHE.allowThis(averageScore);

        // Allow the recruiter to decrypt the average score
        FHE.allow(averageScore, recruiter);
    }
}