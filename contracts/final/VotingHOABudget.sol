// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingHOABudget
/// @notice Homeowners Association budget vote with encrypted property values as voting weight.
///         Homeowners with higher property values get proportionally more voting weight.
///         Budget line items and amounts are partially encrypted for privacy.
contract VotingHOABudget is ZamaEthereumConfig, Ownable {
    struct BudgetProposal {
        string description;
        euint64 requestedAmount;
        euint64 approvalWeight;
        euint64 rejectionWeight;
        bool finalized;
        bool approved;
        uint256 deadline;
    }

    struct Homeowner {
        euint64 propertyValueBps; // encrypted property value weight
        bool registered;
        mapping(uint256 => bool) voted;
    }

    mapping(address => Homeowner) private homeowners;
    address[] public homeownerList;
    mapping(uint256 => BudgetProposal) private proposals;
    uint256 public proposalCount;
    euint64 private _totalWeight;

    event HomeownerRegistered(address indexed h);
    event ProposalCreated(uint256 indexed id);
    event VoteCast(uint256 indexed id, address indexed h);
    event BudgetDecision(uint256 indexed id, bool approved);

    constructor() Ownable(msg.sender) {
        _totalWeight = FHE.asEuint64(0);
        FHE.allowThis(_totalWeight);
    }

    function registerHomeowner(address h, externalEuint64 encValue, bytes calldata proof) external onlyOwner {
        euint64 value = FHE.fromExternal(encValue, proof);
        homeowners[h].propertyValueBps = value;
        homeowners[h].registered = true;
        _totalWeight = FHE.add(_totalWeight, value); // [arithmetic_overflow_underflow]
        euint64 valueScaled = FHE.mul(value, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(homeowners[h].propertyValueBps);
        FHE.allow(homeowners[h].propertyValueBps, h); // [acl_misconfig]
        FHE.allow(_totalWeight, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalWeight);
        homeownerList.push(h);
        emit HomeownerRegistered(h);
    }

    function createProposal(
        string calldata desc,
        externalEuint64 encAmount, bytes calldata proof,
        uint256 daysOpen
    ) external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        BudgetProposal storage p = proposals[id];
        p.description = desc;
        p.requestedAmount = FHE.fromExternal(encAmount, proof);
        p.approvalWeight = FHE.asEuint64(0);
        p.rejectionWeight = FHE.asEuint64(0);
        p.deadline = block.timestamp + daysOpen * 1 days;
        FHE.allowThis(p.requestedAmount);
        FHE.allowThis(p.approvalWeight);
        FHE.allowThis(p.rejectionWeight);
        emit ProposalCreated(id);
    }

    function vote(uint256 id, bool approve) external {
        Homeowner storage h = homeowners[msg.sender];
        require(h.registered, "Not homeowner");
        BudgetProposal storage p = proposals[id];
        require(!p.finalized && block.timestamp <= p.deadline, "Closed");
        require(!h.voted[id], "Already voted");
        h.voted[id] = true;
        if (approve) {
            p.approvalWeight = FHE.add(p.approvalWeight, h.propertyValueBps);
            FHE.allowThis(p.approvalWeight);
        } else {
            p.rejectionWeight = FHE.add(p.rejectionWeight, h.propertyValueBps);
            FHE.allowThis(p.rejectionWeight);
        }
        emit VoteCast(id, msg.sender);
    }

    function finalizeProposal(uint256 id) external onlyOwner {
        BudgetProposal storage p = proposals[id];
        require(!p.finalized, "Already finalized");
        p.finalized = true;
        ebool approved = FHE.gt(p.approvalWeight, p.rejectionWeight);
        p.approved = FHE.isInitialized(approved);
        emit BudgetDecision(id, p.approved);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].approvalWeight, viewer);
        FHE.allow(proposals[id].rejectionWeight, viewer);
        FHE.allow(proposals[id].requestedAmount, viewer);
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