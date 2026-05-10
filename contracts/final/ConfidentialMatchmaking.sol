// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ConfidentialMatchmaking - B2B matchmaking platform: companies submit encrypted capability profiles, matches found privately
contract ConfidentialMatchmaking is ZamaEthereumConfig, Ownable {
    struct CompanyProfile {
        euint64 capabilitiesHash;     // encrypted bitmask of capabilities
        euint64 requirementsHash;     // encrypted bitmask of what they need
        euint64 budgetRange;          // encrypted budget range
        euint8 industryCode;          // encrypted industry sector
        bool registered;
        bool publiclyVisible;
    }

    struct Match {
        address partyA;
        address partyB;
        ebool compatibleCapabilities;
        ebool compatibleBudget;
        uint256 matchedAt;
        bool bothConfirmed;
    }

    mapping(address => CompanyProfile) private profiles;
    mapping(bytes32 => Match) private matches;
    mapping(address => bool) public isMatchmaker;
    uint256 public totalMatches;

    event ProfileRegistered(address indexed company);
    event MatchAttempted(bytes32 indexed matchId, address a, address b);
    event MatchConfirmed(bytes32 indexed matchId);

    constructor() Ownable(msg.sender) {
        isMatchmaker[msg.sender] = true;
    }

    function addMatchmaker(address mm) external onlyOwner { isMatchmaker[mm] = true; }

    function registerProfile(
        externalEuint64 encCapabilities, bytes calldata capProof,
        externalEuint64 encRequirements, bytes calldata reqProof,
        externalEuint64 encBudget, bytes calldata budProof,
        externalEuint8 encIndustry, bytes calldata indProof,
        bool publicVisible
    ) external {
        euint64 caps = FHE.fromExternal(encCapabilities, capProof);
        euint64 reqs = FHE.fromExternal(encRequirements, reqProof);
        euint64 budget = FHE.fromExternal(encBudget, budProof);
        euint8 industry = FHE.fromExternal(encIndustry, indProof);
        profiles[msg.sender] = CompanyProfile({ capabilitiesHash: caps, requirementsHash: reqs,
            budgetRange: budget, industryCode: industry, registered: true, publiclyVisible: publicVisible });
        FHE.allowThis(profiles[msg.sender].capabilitiesHash);
        FHE.allow(profiles[msg.sender].capabilitiesHash, msg.sender);
        FHE.allowThis(profiles[msg.sender].requirementsHash);
        FHE.allow(profiles[msg.sender].requirementsHash, msg.sender);
        FHE.allowThis(profiles[msg.sender].budgetRange);
        FHE.allow(profiles[msg.sender].budgetRange, msg.sender);
        FHE.allowThis(profiles[msg.sender].industryCode);
        emit ProfileRegistered(msg.sender);
    }

    function attemptMatch(address a, address b) external returns (bytes32 matchId) {
        require(isMatchmaker[msg.sender], "Not matchmaker");
        require(profiles[a].registered && profiles[b].registered, "Not registered");
        // Check if A's capabilities satisfy B's requirements
        euint64 capMeetsReq = FHE.and(profiles[a].capabilitiesHash, profiles[b].requirementsHash);
        ebool compatible = FHE.eq(capMeetsReq, profiles[b].requirementsHash);
        // Check budget overlap (simplified: a's budget >= half of b's)
        ebool budgetOk = FHE.ge(profiles[a].budgetRange, FHE.div(profiles[b].budgetRange, 2));
        matchId = keccak256(abi.encodePacked(a, b, block.timestamp));
        matches[matchId] = Match({ partyA: a, partyB: b, compatibleCapabilities: compatible,
            compatibleBudget: budgetOk, matchedAt: block.timestamp, bothConfirmed: false });
        FHE.allowThis(matches[matchId].compatibleCapabilities);
        FHE.allow(matches[matchId].compatibleCapabilities, a);
        FHE.allow(matches[matchId].compatibleCapabilities, b);
        FHE.allowThis(matches[matchId].compatibleBudget);
        FHE.allow(matches[matchId].compatibleBudget, a);
        FHE.allow(matches[matchId].compatibleBudget, b);
        totalMatches++;
        emit MatchAttempted(matchId, a, b);
    }

    function confirmMatch(bytes32 matchId) external {
        Match storage m = matches[matchId];
        require(msg.sender == m.partyA || msg.sender == m.partyB, "Not party");
        m.bothConfirmed = true;
        // Grant mutual profile access
        FHE.allow(profiles[m.partyA].capabilitiesHash, m.partyB);
        FHE.allow(profiles[m.partyB].capabilitiesHash, m.partyA);
        emit MatchConfirmed(matchId);
    }

    function allowProfile(address company, address viewer) external {
        require(msg.sender == company || isMatchmaker[msg.sender], "Unauthorized");
        FHE.allow(profiles[company].capabilitiesHash, viewer);
        FHE.allow(profiles[company].budgetRange, viewer);
    }
}
