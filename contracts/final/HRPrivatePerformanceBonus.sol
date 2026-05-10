// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HRPrivatePerformanceBonus
/// @notice HR performance evaluation system where employee performance scores
///         and bonus allocations are encrypted. Managers set encrypted performance
///         targets; bonuses are computed privately without peer salary visibility.
contract HRPrivatePerformanceBonus is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Employee {
        string employeeId;
        euint16 targetScore;        // encrypted performance target
        euint16 actualScore;        // encrypted actual score
        euint64 baseSalary;         // encrypted base salary
        euint64 bonusAmount;        // encrypted bonus
        euint8 performanceGrade;    // encrypted: A=5, B=4, C=3, D=2, F=1
        uint256 reviewDate;
        bool active;
        bool reviewed;
    }

    struct BonusPool {
        uint256 year;
        euint64 totalPool;
        euint64 allocated;
        euint64 maxBonusPct; // encrypted: max bonus as % of salary (bps)
        bool distributed;
    }

    mapping(address => Employee) private employees;
    address[] public employeeList;
    mapping(uint256 => BonusPool) private bonusPools;
    uint256 public poolCount;
    mapping(address => bool) public isHR;
    mapping(address => bool) public isManager;

    event EmployeeAdded(address indexed emp, string id);
    event PerformanceReviewed(address indexed emp, uint256 year);
    event BonusDistributed(uint256 indexed poolId);

    constructor() Ownable(msg.sender) {
        isHR[msg.sender] = true;
    }

    function addHR(address h) external onlyOwner { isHR[h] = true; }
    function addManager(address m) external onlyOwner { isManager[m] = true; }

    function addEmployee(
        address emp, string calldata employeeId,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint16 encTarget, bytes calldata tProof
    ) external {
        require(isHR[msg.sender], "Not HR");
        employees[emp].employeeId = employeeId;
        employees[emp].baseSalary = FHE.fromExternal(encSalary, sProof);
        employees[emp].targetScore = FHE.fromExternal(encTarget, tProof);
        employees[emp].actualScore = FHE.asEuint16(0);
        employees[emp].bonusAmount = FHE.asEuint64(0);
        employees[emp].performanceGrade = FHE.asEuint8(0);
        employees[emp].active = true;
        FHE.allowThis(employees[emp].baseSalary);
        FHE.allow(employees[emp].baseSalary, emp);
        FHE.allowThis(employees[emp].targetScore);
        FHE.allow(employees[emp].targetScore, emp);
        FHE.allowThis(employees[emp].actualScore);
        FHE.allowThis(employees[emp].bonusAmount);
        FHE.allow(employees[emp].bonusAmount, emp);
        FHE.allowThis(employees[emp].performanceGrade);
        FHE.allow(employees[emp].performanceGrade, emp);
        employeeList.push(emp);
        emit EmployeeAdded(emp, employeeId);
    }

    function conductReview(
        address emp,
        externalEuint16 encActualScore, bytes calldata aProof,
        externalEuint8 encGrade, bytes calldata gProof
    ) external {
        require(isManager[msg.sender] || isHR[msg.sender], "Not authorized");
        employees[emp].actualScore = FHE.fromExternal(encActualScore, aProof);
        employees[emp].performanceGrade = FHE.fromExternal(encGrade, gProof);
        employees[emp].reviewed = true;
        employees[emp].reviewDate = block.timestamp;
        FHE.allowThis(employees[emp].actualScore);
        FHE.allow(employees[emp].actualScore, emp);
        FHE.allowThis(employees[emp].performanceGrade);
        FHE.allow(employees[emp].performanceGrade, emp);
        emit PerformanceReviewed(emp, block.timestamp / 365 days + 1970);
    }

    function createBonusPool(
        uint256 year,
        externalEuint64 encPool, bytes calldata pProof,
        externalEuint64 encMaxPct, bytes calldata mProof
    ) external {
        require(isHR[msg.sender], "Not HR");
        uint256 id = poolCount++;
        bonusPools[id].year = year;
        bonusPools[id].totalPool = FHE.fromExternal(encPool, pProof);
        bonusPools[id].maxBonusPct = FHE.fromExternal(encMaxPct, mProof);
        bonusPools[id].allocated = FHE.asEuint64(0);
        FHE.allowThis(bonusPools[id].totalPool);
        FHE.allowThis(bonusPools[id].maxBonusPct);
        FHE.allowThis(bonusPools[id].allocated);
    }

    function distributeBonus(uint256 poolId) external nonReentrant {
        require(isHR[msg.sender], "Not HR");
        BonusPool storage pool = bonusPools[poolId];
        require(!pool.distributed, "Already distributed");
        pool.distributed = true;
        for (uint256 i = 0; i < employeeList.length; i++) {
            address emp = employeeList[i];
            Employee storage e = employees[emp];
            if (!e.active || !e.reviewed) continue;
            // Bonus proportional to performanceGrade (1-5)
            euint64 bonusCap = FHE.div(FHE.mul(e.baseSalary, pool.maxBonusPct), 10000); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            euint64 gradeMultiplier = FHE.asEuint64(1); // simplified
            euint64 bonusCalc = FHE.mul(bonusCap, gradeMultiplier);
            ebool poolHasFunds = FHE.ge(FHE.sub(pool.totalPool, pool.allocated), bonusCalc);
            euint64 actualBonus = FHE.select(poolHasFunds, bonusCalc, FHE.asEuint64(0));
            e.bonusAmount = actualBonus;
            pool.allocated = FHE.add(pool.allocated, actualBonus);
            FHE.allowThis(e.bonusAmount);
            FHE.allow(e.bonusAmount, emp);
            FHE.allowThis(pool.allocated);
        }
        emit BonusDistributed(poolId);
    }

    function allowEmployeeData(address viewer) external {
        FHE.allow(employees[msg.sender].baseSalary, viewer);
        FHE.allow(employees[msg.sender].bonusAmount, viewer);
        FHE.allow(employees[msg.sender].performanceGrade, viewer);
    }
}
