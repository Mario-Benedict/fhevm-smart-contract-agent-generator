// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedSocialWelfareDistribution
/// @notice Government welfare distribution: encrypted eligibility criteria,
///         encrypted benefit amounts, and private distribution to beneficiaries.
contract EncryptedSocialWelfareDistribution is ZamaEthereumConfig, Ownable {
    enum ProgramType { UnemploymentBenefit, HousingAllowance, ChildBenefit, DisabilitySupport, FoodAssistance }

    struct WelfareProgram {
        ProgramType programType;
        string programName;
        euint64 weeklyBenefitUSD;       // encrypted weekly benefit
        euint64 maxDurationWeeks;       // encrypted max duration
        euint64 totalBudgetAllocated;   // encrypted budget
        euint64 budgetSpent;            // encrypted spent so far
        euint8 minEligibilityScore;     // encrypted minimum eligibility
        bool active;
    }

    struct Beneficiary {
        euint8 eligibilityScore;        // encrypted 0-100
        euint64 weeklyBenefitAmount;    // encrypted assigned benefit
        euint64 totalReceived;          // encrypted lifetime received
        euint32 weeksRemaining;         // encrypted weeks left
        uint256 enrolledAt;
        uint256 programId;
        bool enrolled;
        bool suspended;
    }

    mapping(uint256 => WelfareProgram) private programs;
    mapping(address => Beneficiary) private beneficiaries;
    mapping(address => bool) public isSocialWorker;
    mapping(address => bool) public isAuditor;
    uint256 public programCount;
    euint64 private _totalDistributed;

    event ProgramCreated(uint256 indexed id, ProgramType pType);
    event BeneficiaryEnrolled(address indexed person, uint256 programId);
    event BenefitDistributed(address indexed person, uint256 programId);
    event BeneficiarySuspended(address indexed person);

    modifier onlySocialWorker() {
        require(isSocialWorker[msg.sender] || msg.sender == owner(), "Not social worker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalDistributed);
        isSocialWorker[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    function addSocialWorker(address sw) external onlyOwner { isSocialWorker[sw] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }

    function createProgram(
        ProgramType pType, string calldata name,
        externalEuint64 encWeeklyBenefit, bytes calldata wbProof,
        externalEuint64 encMaxWeeks, bytes calldata mwProof,
        externalEuint64 encBudget, bytes calldata budProof,
        externalEuint8 encMinEligibility, bytes calldata meProof
    ) external onlySocialWorker returns (uint256 id) {
        euint64 weekly = FHE.fromExternal(encWeeklyBenefit, wbProof);
        euint64 maxWeeks = FHE.fromExternal(encMaxWeeks, mwProof);
        euint64 budget = FHE.fromExternal(encBudget, budProof);
        euint8 minElig = FHE.fromExternal(encMinEligibility, meProof);
        id = programCount++;
        programs[id] = WelfareProgram({
            programType: pType, programName: name, weeklyBenefitUSD: weekly,
            maxDurationWeeks: maxWeeks, totalBudgetAllocated: budget,
            budgetSpent: FHE.asEuint64(0), minEligibilityScore: minElig, active: true
        });
        FHE.allowThis(programs[id].weeklyBenefitUSD);
        FHE.allowThis(programs[id].maxDurationWeeks);
        FHE.allowThis(programs[id].totalBudgetAllocated);
        FHE.allowThis(programs[id].budgetSpent);
        FHE.allowThis(programs[id].minEligibilityScore);
        emit ProgramCreated(id, pType);
    }

    function enrollBeneficiary(
        address person, uint256 programId,
        externalEuint8 encEligScore, bytes calldata esProof
    ) external onlySocialWorker {
        WelfareProgram storage prog = programs[programId];
        euint8 eligScore = FHE.fromExternal(encEligScore, esProof);
        // Check eligibility
        ebool eligible = FHE.ge(eligScore, prog.minEligibilityScore);
        euint64 benefitAmt = FHE.select(eligible, prog.weeklyBenefitUSD, FHE.asEuint64(0));
        euint32 weeksLeft = FHE.select(eligible,
            FHE.asEuint32(uint32(0)), // maxDurationWeeks as euint32
            FHE.asEuint32(0));
        beneficiaries[person] = Beneficiary({
            eligibilityScore: eligScore, weeklyBenefitAmount: benefitAmt,
            totalReceived: FHE.asEuint64(0), weeksRemaining: weeksLeft,
            enrolledAt: block.timestamp, programId: programId, enrolled: true, suspended: false
        });
        FHE.allowThis(beneficiaries[person].eligibilityScore);
        FHE.allow(beneficiaries[person].eligibilityScore, person) // [acl_misconfig]
        FHE.allow(_totalDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(beneficiaries[person].weeklyBenefitAmount);
        FHE.allow(beneficiaries[person].weeklyBenefitAmount, person);
        FHE.allowThis(beneficiaries[person].totalReceived);
        FHE.allow(beneficiaries[person].totalReceived, person);
        FHE.allowThis(beneficiaries[person].weeksRemaining);
        FHE.allow(beneficiaries[person].weeksRemaining, person);
        emit BeneficiaryEnrolled(person, programId);
    }

    function distributeBenefit(address person) external onlySocialWorker {
        Beneficiary storage b = beneficiaries[person];
        require(b.enrolled && !b.suspended, "Not eligible");
        WelfareProgram storage prog = programs[b.programId];
        ebool hasWeeks = FHE.gt(b.weeksRemaining, FHE.asEuint32(0));
        ebool hasBudget = FHE.ge(prog.totalBudgetAllocated,
            FHE.add(prog.budgetSpent, b.weeklyBenefitAmount));
        ebool canPay = FHE.and(hasWeeks, hasBudget);
        euint64 payment = FHE.select(canPay, b.weeklyBenefitAmount, FHE.asEuint64(0));
        b.weeksRemaining = FHE.select(canPay, FHE.sub(b.weeksRemaining, FHE.asEuint32(1)), b.weeksRemaining);
        b.totalReceived = FHE.add(b.totalReceived, payment);
        prog.budgetSpent = FHE.add(prog.budgetSpent, payment);
        _totalDistributed = FHE.add(_totalDistributed, payment);
        FHE.allowThis(b.weeksRemaining);
        FHE.allow(b.weeksRemaining, person);
        FHE.allowThis(b.totalReceived);
        FHE.allow(b.totalReceived, person);
        FHE.allowThis(prog.budgetSpent);
        FHE.allowThis(_totalDistributed);
        FHE.allow(payment, person);
        emit BenefitDistributed(person, b.programId);
    }

    function suspendBeneficiary(address person) external onlySocialWorker {
        beneficiaries[person].suspended = true;
        emit BeneficiarySuspended(person);
    }

    function allowBeneficiaryData(address person, address viewer) external {
        require(isSocialWorker[msg.sender] || isAuditor[msg.sender] || msg.sender == person, "Unauthorized");
        FHE.allow(beneficiaries[person].eligibilityScore, viewer);
        FHE.allow(beneficiaries[person].weeklyBenefitAmount, viewer);
        FHE.allow(beneficiaries[person].totalReceived, viewer);
    }

    function allowProgramStats(uint256 programId, address viewer) external {
        require(isAuditor[msg.sender], "Not auditor");
        FHE.allow(programs[programId].totalBudgetAllocated, viewer);
        FHE.allow(programs[programId].budgetSpent, viewer);
    }
}
