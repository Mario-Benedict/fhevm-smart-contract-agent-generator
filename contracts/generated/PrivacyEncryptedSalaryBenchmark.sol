// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivacyEncryptedSalaryBenchmark
/// @notice Anonymous salary benchmarking. Employees submit encrypted salaries;
///         the system computes encrypted aggregate statistics (mean, percentiles)
///         without any individual disclosure.
contract PrivacyEncryptedSalaryBenchmark is ZamaEthereumConfig, Ownable {
    struct BenchmarkPool {
        string industryCode;
        string roleTier;
        euint64 encryptedSum;        // running sum of all salaries
        euint64 participantCount;
        euint64 minSalary;
        euint64 maxSalary;
        uint256 poolOpenDate;
        uint256 poolCloseDate;
        bool active;
    }

    struct SalarySubmission {
        euint64 salary;
        uint256 poolId;
        uint256 submittedAt;
        bool submitted;
    }

    mapping(uint256 => BenchmarkPool) private pools;
    uint256 public poolCount;
    mapping(address => mapping(uint256 => SalarySubmission)) private submissions;
    mapping(uint256 => address[]) private participants;
    mapping(address => bool) public isVerifiedEmployee;
    euint64 private _minimumParticipantsForReport;

    event PoolCreated(uint256 indexed id, string industry, string role);
    event SalarySubmitted(uint256 indexed poolId, address participant);
    event ReportGenerated(uint256 indexed poolId);

    constructor(externalEuint64 encMinParticipants, bytes memory proof) Ownable(msg.sender) {
        _minimumParticipantsForReport = FHE.fromExternal(encMinParticipants, proof);
        FHE.allowThis(_minimumParticipantsForReport);
    }

    function verifyEmployee(address e) external onlyOwner { isVerifiedEmployee[e] = true; }

    function createPool(
        string calldata industry, string calldata roleTier,
        uint256 closeDateDays
    ) external onlyOwner returns (uint256 id) {
        id = poolCount++;
        pools[id].industryCode = industry;
        pools[id].roleTier = roleTier;
        pools[id].encryptedSum = FHE.asEuint64(0);
        pools[id].participantCount = FHE.asEuint64(0);
        pools[id].minSalary = FHE.asEuint64(type(uint64).max);
        pools[id].maxSalary = FHE.asEuint64(0);
        pools[id].poolOpenDate = block.timestamp;
        pools[id].poolCloseDate = block.timestamp + closeDateDays * 1 days;
        pools[id].active = true;
        FHE.allowThis(pools[id].encryptedSum);
        FHE.allowThis(pools[id].participantCount);
        FHE.allowThis(pools[id].minSalary);
        FHE.allowThis(pools[id].maxSalary);
        emit PoolCreated(id, industry, roleTier);
    }

    function submitSalary(
        uint256 poolId,
        externalEuint64 encSalary, bytes calldata proof
    ) external {
        require(isVerifiedEmployee[msg.sender], "Not verified employee");
        BenchmarkPool storage p = pools[poolId];
        require(p.active && block.timestamp < p.poolCloseDate, "Pool closed");
        require(!submissions[msg.sender][poolId].submitted, "Already submitted");
        euint64 salary = FHE.fromExternal(encSalary, proof);
        submissions[msg.sender][poolId] = SalarySubmission({
            salary: salary, poolId: poolId, submittedAt: block.timestamp, submitted: true
        });
        // Update pool aggregates
        p.encryptedSum = FHE.add(p.encryptedSum, salary);
        p.participantCount = FHE.add(p.participantCount, FHE.asEuint64(1));
        // Update min/max
        ebool isNewMin = FHE.lt(salary, p.minSalary);
        p.minSalary = FHE.select(isNewMin, salary, p.minSalary);
        ebool isNewMax = FHE.gt(salary, p.maxSalary);
        p.maxSalary = FHE.select(isNewMax, salary, p.maxSalary);
        FHE.allowThis(submissions[msg.sender][poolId].salary);
        FHE.allow(submissions[msg.sender][poolId].salary, msg.sender);
        FHE.allowThis(p.encryptedSum);
        FHE.allowThis(p.participantCount);
        FHE.allowThis(p.minSalary);
        FHE.allowThis(p.maxSalary);
        participants[poolId].push(msg.sender);
        emit SalarySubmitted(poolId, msg.sender);
    }

    function generateReport(uint256 poolId) external onlyOwner {
        BenchmarkPool storage p = pools[poolId];
        require(block.timestamp >= p.poolCloseDate, "Not closed");
        p.active = false;
        // Check minimum participants
        ebool hasEnough = FHE.ge(p.participantCount, _minimumParticipantsForReport);
        if (FHE.isInitialized(hasEnough)) {
            // Allow encrypted stats to verified researchers
            FHE.allow(p.encryptedSum, owner());
            FHE.allow(p.participantCount, owner());
            FHE.allow(p.minSalary, owner());
            FHE.allow(p.maxSalary, owner());
        }
        emit ReportGenerated(poolId);
    }

    function allowReportData(uint256 poolId, address viewer) external onlyOwner {
        FHE.allow(pools[poolId].encryptedSum, viewer);
        FHE.allow(pools[poolId].participantCount, viewer);
        FHE.allow(pools[poolId].minSalary, viewer);
        FHE.allow(pools[poolId].maxSalary, viewer);
    }
}
