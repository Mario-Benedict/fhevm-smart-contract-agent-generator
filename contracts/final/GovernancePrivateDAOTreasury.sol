// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title GovernancePrivateDAOTreasury
/// @notice DAO treasury with encrypted budget allocations per committee.
///         Committees receive hidden budget allocations; spending is approved
///         without revealing other committees' budgets.
contract GovernancePrivateDAOTreasury is ZamaEthereumConfig, Ownable {
    struct Committee {
        string name;
        euint64 allocatedBudget;
        euint64 spentBudget;
        euint64 pendingRequests;
        address lead;
        bool active;
    }

    struct SpendingRequest {
        uint256 committeeId;
        string description;
        euint64 amount;
        address requester;
        bool approved;
        bool executed;
        bool rejected;
        uint256 createdAt;
    }

    mapping(uint256 => Committee) private committees;
    uint256 public committeeCount;
    mapping(uint256 => SpendingRequest) private requests;
    uint256 public requestCount;
    euint64 private _totalTreasury;
    euint64 private _totalAllocated;

    event CommitteeCreated(uint256 indexed id, string name);
    event BudgetAllocated(uint256 indexed committeeId);
    event SpendingRequested(uint256 indexed requestId, uint256 committeeId);
    event SpendingApproved(uint256 indexed requestId);
    event SpendingRejected(uint256 indexed requestId);

    constructor(externalEuint64 encTreasury, bytes memory proof) Ownable(msg.sender) {
        _totalTreasury = FHE.fromExternal(encTreasury, proof);
        _totalAllocated = FHE.asEuint64(0);
        FHE.allowThis(_totalTreasury);
        FHE.allowThis(_totalAllocated);
    }

    function createCommittee(string calldata name, address lead) external onlyOwner returns (uint256 id) {
        id = committeeCount++;
        committees[id].name = name;
        committees[id].lead = lead;
        committees[id].allocatedBudget = FHE.asEuint64(0);
        committees[id].spentBudget = FHE.asEuint64(0);
        committees[id].pendingRequests = FHE.asEuint64(0);
        committees[id].active = true;
        FHE.allowThis(committees[id].allocatedBudget);
        FHE.allow(committees[id].allocatedBudget, lead);
        FHE.allowThis(committees[id].spentBudget);
        FHE.allow(committees[id].spentBudget, lead);
        FHE.allowThis(committees[id].pendingRequests);
        emit CommitteeCreated(id, name);
    }

    function allocateBudget(
        uint256 committeeId,
        externalEuint64 encAmount, bytes calldata proof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.ge(FHE.sub(_totalTreasury, _totalAllocated), amount); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        committees[committeeId].allocatedBudget = FHE.add(committees[committeeId].allocatedBudget, actual);
        _totalAllocated = FHE.add(_totalAllocated, actual);
        FHE.allowThis(committees[committeeId].allocatedBudget);
        FHE.allow(committees[committeeId].allocatedBudget, committees[committeeId].lead);
        FHE.allowThis(_totalAllocated);
        emit BudgetAllocated(committeeId);
    }

    function requestSpending(
        uint256 committeeId, string calldata desc,
        externalEuint64 encAmount, bytes calldata proof
    ) external returns (uint256 id) {
        require(committees[committeeId].lead == msg.sender, "Not committee lead");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 remaining = FHE.sub(committees[committeeId].allocatedBudget, committees[committeeId].spentBudget);
        ebool hasBudget = FHE.ge(remaining, amount);
        euint64 validAmount = FHE.select(hasBudget, amount, FHE.asEuint64(0));
        id = requestCount++;
        requests[id] = SpendingRequest({
            committeeId: committeeId, description: desc,
            amount: validAmount, requester: msg.sender,
            approved: false, executed: false, rejected: false,
            createdAt: block.timestamp
        });
        committees[committeeId].pendingRequests = FHE.add(committees[committeeId].pendingRequests, validAmount);
        FHE.allowThis(requests[id].amount);
        FHE.allow(requests[id].amount, msg.sender);
        FHE.allowThis(committees[committeeId].pendingRequests);
        emit SpendingRequested(id, committeeId);
    }

    function approveSpending(uint256 requestId) external onlyOwner {
        SpendingRequest storage req = requests[requestId];
        require(!req.approved && !req.rejected, "Already decided");
        req.approved = true;
        req.executed = true;
        Committee storage c = committees[req.committeeId];
        c.spentBudget = FHE.add(c.spentBudget, req.amount);
        c.pendingRequests = FHE.sub(c.pendingRequests, req.amount);
        FHE.allowThis(c.spentBudget);
        FHE.allow(c.spentBudget, c.lead);
        FHE.allow(req.amount, req.requester);
        FHE.allowThis(c.pendingRequests);
        emit SpendingApproved(requestId);
    }

    function rejectSpending(uint256 requestId) external onlyOwner {
        SpendingRequest storage req = requests[requestId];
        require(!req.approved && !req.rejected, "Already decided");
        req.rejected = true;
        committees[req.committeeId].pendingRequests = FHE.sub(
            committees[req.committeeId].pendingRequests, req.amount
        );
        FHE.allowThis(committees[req.committeeId].pendingRequests);
        emit SpendingRejected(requestId);
    }

    function allowTreasuryStats(address viewer) external onlyOwner {
        FHE.allow(_totalTreasury, viewer);
        FHE.allow(_totalAllocated, viewer);
    }
}
