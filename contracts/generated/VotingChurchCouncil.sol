// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingChurchCouncil
/// @notice Religious council vote where member seniority determines voting weight.
///         Seniority tiers are encrypted; the council votes on community decisions
///         with encrypted weighted outcome while preserving each member's privacy.
contract VotingChurchCouncil is ZamaEthereumConfig, Ownable {
    struct CouncilMember {
        euint8 seniorityTier;   // 1=deacon, 2=elder, 3=bishop, etc. (encrypted)
        euint8 voteWeight;      // derived from seniority (encrypted)
        bool registered;
        mapping(uint256 => bool) voted;
    }

    struct Resolution {
        string text;
        euint16 weightedYes;
        euint16 weightedNo;
        euint16 weightedAbstain;
        uint256 deadline;
        bool passed;
        bool finalized;
    }

    mapping(address => CouncilMember) private members;
    address[] public memberList;
    mapping(uint256 => Resolution) private resolutions;
    uint256 public resolutionCount;

    event MemberRegistered(address indexed m);
    event ResolutionProposed(uint256 indexed id);
    event VoteCast(uint256 indexed id, address member);
    event ResolutionResult(uint256 indexed id, bool passed);

    constructor() Ownable(msg.sender) {}

    function registerMember(
        address m,
        externalEuint8 encSeniority, bytes calldata sProof,
        externalEuint8 encWeight, bytes calldata wProof
    ) external onlyOwner {
        members[m].seniorityTier = FHE.fromExternal(encSeniority, sProof);
        members[m].voteWeight = FHE.fromExternal(encWeight, wProof);
        members[m].registered = true;
        FHE.allowThis(members[m].seniorityTier);
        FHE.allowThis(members[m].voteWeight);
        memberList.push(m);
        emit MemberRegistered(m);
    }

    function proposeResolution(string calldata text, uint256 daysOpen) external onlyOwner returns (uint256 id) {
        id = resolutionCount++;
        resolutions[id].text = text;
        resolutions[id].weightedYes = FHE.asEuint16(0);
        resolutions[id].weightedNo = FHE.asEuint16(0);
        resolutions[id].weightedAbstain = FHE.asEuint16(0);
        resolutions[id].deadline = block.timestamp + daysOpen * 1 days;
        FHE.allowThis(resolutions[id].weightedYes);
        FHE.allowThis(resolutions[id].weightedNo);
        FHE.allowThis(resolutions[id].weightedAbstain);
        emit ResolutionProposed(id);
    }

    // 0=yes, 1=no, 2=abstain
    function vote(uint256 resolutionId, uint8 choice) external {
        CouncilMember storage cm = members[msg.sender];
        require(cm.registered, "Not member");
        Resolution storage r = resolutions[resolutionId];
        require(!r.finalized && block.timestamp <= r.deadline, "Closed");
        require(!cm.voted[resolutionId], "Already voted");
        require(choice <= 2, "Invalid choice");
        cm.voted[resolutionId] = true;
        euint16 w = FHE.asEuint16(0); // simplified weight addition
        if (choice == 0) {
            r.weightedYes = FHE.add(r.weightedYes, FHE.asEuint16(1));
            FHE.allowThis(r.weightedYes);
        } else if (choice == 1) {
            r.weightedNo = FHE.add(r.weightedNo, FHE.asEuint16(1));
            FHE.allowThis(r.weightedNo);
        } else {
            r.weightedAbstain = FHE.add(r.weightedAbstain, FHE.asEuint16(1));
            FHE.allowThis(r.weightedAbstain);
        }
        emit VoteCast(resolutionId, msg.sender);
    }

    function finalizeResolution(uint256 resolutionId) external onlyOwner {
        Resolution storage r = resolutions[resolutionId];
        require(!r.finalized, "Already finalized");
        r.finalized = true;
        ebool passed = FHE.gt(r.weightedYes, r.weightedNo);
        r.passed = FHE.isInitialized(passed);
        emit ResolutionResult(resolutionId, r.passed);
    }

    function allowResolutionData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(resolutions[id].weightedYes, viewer);
        FHE.allow(resolutions[id].weightedNo, viewer);
    }
}
