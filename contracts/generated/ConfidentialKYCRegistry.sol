// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ConfidentialKYCRegistry is ZamaEthereumConfig, AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    struct EncryptedIdentity {
        euint8 encryptedAge;
        euint16 encryptedJurisdictionCode;
        euint32 encryptedRiskScore; // Lower is better
        bool isVerified;
    }

    mapping(address => EncryptedIdentity) private identities;

    event IdentityIssued(address indexed user);
    event VerificationRequested(address indexed user, address indexed requester);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
    }

    // Trusted KYC provider issues the encrypted identity
    function issueIdentity(
        address user,
        externalEuint8 memory extAge,
        externalEuint16 memory extJurisdiction,
        externalEuint32 memory extRiskScore,
        bytes calldata proofAge,
        bytes calldata proofJurisdiction,
        bytes calldata proofRisk
    ) external onlyRole(ISSUER_ROLE) {
        euint8 age = FHE.fromExternal(extAge, proofAge);
        euint16 jurisdiction = FHE.fromExternal(extJurisdiction, proofJurisdiction);
        euint32 riskScore = FHE.fromExternal(extRiskScore, proofRisk);

        FHE.allowThis(age);
        FHE.allowThis(jurisdiction);
        FHE.allowThis(riskScore);

        identities[user] = EncryptedIdentity({
            encryptedAge: age,
            encryptedJurisdictionCode: jurisdiction,
            encryptedRiskScore: riskScore,
            isVerified: true
        });

        emit IdentityIssued(user);
    }

    // A dApp requests proof of adulthood without seeing the exact age
    function proveAdulthood(address user) external {
        require(identities[user].isVerified, "No identity found");
        
        euint8 userAge = identities[user].encryptedAge;
        euint8 legalAge = FHE.asEuint8(18);
        FHE.allowThis(legalAge);

        // Condition: Age >= 18
        ebool isAdult = FHE.ge(userAge, legalAge);
        
        // FHE.req will revert the transaction if the user is not an adult.
        // If the transaction succeeds, the caller knows the user is 18+.
        FHE.req(isAdult);

        emit VerificationRequested(user, msg.sender);
    }

    // A lending dApp checks if a user is below a certain risk threshold
    function validateRiskThreshold(address user, uint32 maxAcceptableRisk) external {
        require(identities[user].isVerified, "No identity found");

        euint32 userRisk = identities[user].encryptedRiskScore;
        euint32 maxRisk = FHE.asEuint32(maxAcceptableRisk);
        FHE.allowThis(maxRisk);

        // Condition: userRisk <= maxAcceptableRisk
        ebool isSafe = FHE.le(userRisk, maxRisk);
        FHE.req(isSafe);

        emit VerificationRequested(user, msg.sender);
    }
}