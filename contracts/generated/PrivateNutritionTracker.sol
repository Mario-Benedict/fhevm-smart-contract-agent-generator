// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateNutritionTracker - Encrypted daily nutrition logs with selective coach visibility
contract PrivateNutritionTracker is ZamaEthereumConfig, Ownable {
    struct NutritionLog {
        euint16 caloriesKcal;
        euint8  proteinGrams;
        euint8  carbGrams;
        euint8  fatGrams;
        euint8  fiberGrams;
        euint8  sugarGrams;
        euint32 logDate;     // unix day timestamp
        bool    logged;
    }

    struct HealthGoal {
        euint16 targetCalories;
        euint8  targetProtein;
        euint8  targetCarbs;
        euint8  targetFat;
        bool    active;
    }

    mapping(address => mapping(uint32 => NutritionLog)) private dailyLogs;
    mapping(address => HealthGoal)  private goals;
    mapping(address => address)     public assignedCoach;
    mapping(address => bool)        public registeredCoaches;
    mapping(address => uint256)     public totalDaysLogged;

    event UserRegistered(address indexed user);
    event LogRecorded(address indexed user, uint32 logDate);
    event GoalSet(address indexed user);
    event CoachAssigned(address indexed user, address indexed coach);

    constructor() Ownable(msg.sender) {}

    function registerCoach(address coach) external onlyOwner {
        registeredCoaches[coach] = true;
    }

    function registerUser() external {
        HealthGoal storage g = goals[msg.sender];
        g.targetCalories = FHE.asEuint16(2000);
        g.targetProtein  = FHE.asEuint8(50);
        g.targetCarbs    = FHE.asEuint8(250);
        g.targetFat      = FHE.asEuint8(65);
        g.active         = true;
        FHE.allowThis(g.targetCalories); FHE.allowThis(g.targetProtein);
        FHE.allowThis(g.targetCarbs); FHE.allowThis(g.targetFat);
        FHE.allow(g.targetCalories, msg.sender);
        emit UserRegistered(msg.sender);
    }

    function setGoal(
        externalEuint16 encCal,     bytes calldata calProof,
        externalEuint8 encProtein, bytes calldata proteinProof,
        externalEuint8 encCarbs,   bytes calldata carbsProof,
        externalEuint8 encFat,     bytes calldata fatProof
    ) external {
        HealthGoal storage g = goals[msg.sender];
        g.targetCalories = FHE.fromExternal(encCal,     calProof);
        g.targetProtein  = FHE.fromExternal(encProtein, proteinProof);
        g.targetCarbs    = FHE.fromExternal(encCarbs,   carbsProof);
        g.targetFat      = FHE.fromExternal(encFat,     fatProof);
        FHE.allowThis(g.targetCalories); FHE.allowThis(g.targetProtein);
        FHE.allowThis(g.targetCarbs); FHE.allowThis(g.targetFat);
        FHE.allow(g.targetCalories, msg.sender);
        address coach = assignedCoach[msg.sender];
        if (coach != address(0)) { FHE.allow(g.targetCalories, coach); FHE.allow(g.targetProtein, coach); }
        emit GoalSet(msg.sender);
    }

    function recordDailyLog(
        uint32 logDate,
        externalEuint16 encCal,    bytes calldata calProof,
        externalEuint8 encProt,   bytes calldata protProof,
        externalEuint8 encCarb,   bytes calldata carbProof,
        externalEuint8 encFat,    bytes calldata fatProof,
        externalEuint8 encFiber,  bytes calldata fiberProof,
        externalEuint8 encSugar,  bytes calldata sugarProof
    ) external {
        NutritionLog storage l = dailyLogs[msg.sender][logDate];
        require(!l.logged, "Already logged today");
        l.caloriesKcal = FHE.fromExternal(encCal,   calProof);
        l.proteinGrams = FHE.fromExternal(encProt,  protProof);
        l.carbGrams    = FHE.fromExternal(encCarb,  carbProof);
        l.fatGrams     = FHE.fromExternal(encFat,   fatProof);
        l.fiberGrams   = FHE.fromExternal(encFiber, fiberProof);
        l.sugarGrams   = FHE.fromExternal(encSugar, sugarProof);
        l.logDate      = logDate;
        l.logged       = true;
        FHE.allowThis(l.caloriesKcal); FHE.allowThis(l.proteinGrams);
        FHE.allowThis(l.carbGrams); FHE.allowThis(l.fatGrams);
        FHE.allowThis(l.fiberGrams); FHE.allowThis(l.sugarGrams);
        FHE.allow(l.caloriesKcal, msg.sender);
        address coach = assignedCoach[msg.sender];
        if (coach != address(0)) {
            FHE.allow(l.caloriesKcal, coach); FHE.allow(l.proteinGrams, coach);
        }
        totalDaysLogged[msg.sender]++;
        emit LogRecorded(msg.sender, logDate);
    }

    function assignCoach(address coach) external {
        require(registeredCoaches[coach], "Not a registered coach");
        assignedCoach[msg.sender] = coach;
        HealthGoal storage g = goals[msg.sender];
        FHE.allow(g.targetCalories, coach); FHE.allow(g.targetProtein, coach);
        emit CoachAssigned(msg.sender, coach);
    }
}
