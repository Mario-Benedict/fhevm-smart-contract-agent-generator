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
        euint64 scoreWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 scoreExposure = FHE.sub(scoreWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]



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