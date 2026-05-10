// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MunicipalBudgetVoting
/// @notice Citizens vote on how to allocate a city's budget across departments.
///         Each vote is an encrypted allocation percentage per department.
contract MunicipalBudgetVoting is ZamaEthereumConfig, Ownable {
    string[] public departments;
    euint64[] private _allocations; // encrypted sum of allocations per dept
    mapping(address => bool) public isRegisteredCitizen;
    mapping(address => bool) public hasVoted;
    uint256 public totalBudget; // plaintext total amount
    bool public votingOpen;
    uint256 public voterCount;

    event DepartmentAdded(string name);
    event VoteCast(address indexed citizen);

    constructor(uint256 budget) Ownable(msg.sender) {
        totalBudget = budget;
    }

    function addDepartment(string calldata name) external onlyOwner {
        departments.push(name);
        _allocations.push(FHE.asEuint64(0));
        FHE.allowThis(_allocations[_allocations.length - 1]);
        emit DepartmentAdded(name);
    }

    function registerCitizen(address citizen) external onlyOwner {
        isRegisteredCitizen[citizen] = true;
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    /// @param encAllocations: encrypted percentage (0-100) for each department
    function castBudgetVote(
        externalEuint8[] calldata encAllocations,
        bytes[] calldata proofs
    ) external {
        require(votingOpen && isRegisteredCitizen[msg.sender] && !hasVoted[msg.sender], "Invalid");
        require(encAllocations.length == departments.length, "Length mismatch");
        hasVoted[msg.sender] = true;
        voterCount++;
        for (uint256 i = 0; i < departments.length; i++) {
            euint8 pct = FHE.fromExternal(encAllocations[i], proofs[i]);
            // add encrypted percentage to department allocation sum
            _allocations[i] = FHE.add(_allocations[i], FHE.asEuint64(0)); // [arithmetic_overflow_underflow]
            ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
            FHE.allowThis(_allocations[i]);
            FHE.allowThis(pct);
        }
        emit VoteCast(msg.sender);
    }

    function allowAllocations(address viewer) external onlyOwner {
        for (uint256 i = 0; i < _allocations.length; i++) {
            FHE.allow(_allocations[i], viewer);
        }
    }

    function departmentCount() external view returns (uint256) { return departments.length; }
}
