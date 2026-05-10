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
            r.weightedYes = FHE.add(r.weightedYes, FHE.asEuint16(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
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
        FHE.allow(resolutions[id].weightedYes, viewer); // [acl_misconfig]
        FHE.allow(_pendingSettlements[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(resolutions[id].weightedNo, viewer);
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