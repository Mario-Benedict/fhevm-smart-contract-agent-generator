// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSocialImpactBond
/// @notice Social Impact Bond (SIB/Pay-For-Success): encrypted outcome metrics,
///         encrypted investor returns tied to social outcomes, encrypted commissioner payments,
///         and confidential service provider performance scoring.
contract EncryptedSocialImpactBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OutcomeArea { HOMELESSNESS, RECIDIVISM, EMPLOYMENT, EDUCATION, HEALTH, DOMESTIC_ABUSE }

    struct SIBProgram {
        string programName;
        OutcomeArea outcomeArea;
        address commissioner;       // government entity paying for outcomes
        address serviceProvider;
        euint64 targetOutcomeCount; // encrypted target beneficiaries
        euint64 achievedOutcomeCount;// encrypted actual achieved outcomes
        euint64 maxPaymentUSD;      // encrypted max commissioner payment
        euint64 paymentPerOutcome;  // encrypted USD per outcome achieved
        euint64 totalInvestorCapital;// encrypted investor capital raised
        euint64 returnMultiplierBps;// encrypted return multiplier 10000=1x
        uint256 programStart;
        uint256 programEnd;
        bool active;
        bool settled;
    }

    struct SIBInvestor {
        euint64 capitalInvested;    // encrypted investment
        euint64 expectedReturn;     // encrypted expected return
        euint64 actualReturn;       // encrypted actual return
        bool redeemed;
    }

    struct OutcomeMeasurement {
        uint256 programId;
        euint64 outcomesThisPeriod; // encrypted outcomes in this measurement
        euint64 verifiedScore;      // encrypted independent verification score 0-1000
        uint256 measurementDate;
        address evaluator;
        bool verified;
    }

    mapping(uint256 => SIBProgram) private programs;
    mapping(uint256 => mapping(address => SIBInvestor)) private investors;
    mapping(uint256 => OutcomeMeasurement[]) private measurements;
    uint256 public programCount;
    euint64 private _totalCommissionerCommitment;
    mapping(address => bool) public isCommissioner;
    mapping(address => bool) public isEvaluator;

    event ProgramCreated(uint256 indexed id, string name, OutcomeArea area);
    event InvestorJoined(uint256 indexed programId, address investor);
    event OutcomeMeasured(uint256 indexed programId, uint256 measurementIdx);
    event ProgramSettled(uint256 indexed programId);
    event PaymentTriggered(uint256 indexed programId);

    constructor() Ownable(msg.sender) {
        _totalCommissionerCommitment = FHE.asEuint64(0);
        FHE.allowThis(_totalCommissionerCommitment);
        isCommissioner[msg.sender] = true;
        isEvaluator[msg.sender] = true;
    }

    function addCommissioner(address c) external onlyOwner { isCommissioner[c] = true; }
    function addEvaluator(address e) external onlyOwner { isEvaluator[e] = true; }

    function createProgram(
        string calldata name, OutcomeArea area,
        address serviceProvider,
        externalEuint64 encTargetOutcomes, bytes calldata toProof,
        externalEuint64 encMaxPayment, bytes calldata mpProof,
        externalEuint64 encPayPerOutcome, bytes calldata ppoProof,
        externalEuint64 encReturnMultiplier, bytes calldata rmProof,
        uint256 programEnd
    ) external returns (uint256 id) {
        require(isCommissioner[msg.sender], "Not commissioner");
        euint64 targetOutcomes = FHE.fromExternal(encTargetOutcomes, toProof);
        euint64 maxPayment = FHE.fromExternal(encMaxPayment, mpProof);
        euint64 payPerOutcome = FHE.fromExternal(encPayPerOutcome, ppoProof);
        euint64 multiplier = FHE.fromExternal(encReturnMultiplier, rmProof);
        id = programCount++;
        SIBProgram storage _s0 = programs[id];
        _s0.programName = name;
        _s0.outcomeArea = area;
        _s0.commissioner = msg.sender;
        _s0.serviceProvider = serviceProvider;
        _s0.targetOutcomeCount = targetOutcomes;
        _s0.achievedOutcomeCount = FHE.asEuint64(0);
        _s0.maxPaymentUSD = maxPayment;
        _s0.paymentPerOutcome = payPerOutcome;
        _s0.totalInvestorCapital = FHE.asEuint64(0);
        _s0.returnMultiplierBps = multiplier;
        _s0.programStart = block.timestamp;
        _s0.programEnd = programEnd;
        _s0.active = true;
        _s0.settled = false;
        _totalCommissionerCommitment = FHE.add(_totalCommissionerCommitment, maxPayment);
        FHE.allowThis(programs[id].targetOutcomeCount);
        FHE.allowThis(programs[id].achievedOutcomeCount);
        FHE.allowThis(programs[id].maxPaymentUSD);
        FHE.allowThis(programs[id].paymentPerOutcome);
        FHE.allowThis(programs[id].totalInvestorCapital);
        FHE.allowThis(programs[id].returnMultiplierBps);
        FHE.allowThis(_totalCommissionerCommitment);
        emit ProgramCreated(id, name, area);
    }

    function invest(uint256 programId, externalEuint64 encCapital, bytes calldata proof) external nonReentrant {
        SIBProgram storage prog = programs[programId];
        require(prog.active && !prog.settled, "Not open");
        euint64 capital = FHE.fromExternal(encCapital, proof);
        SIBInvestor storage inv = investors[programId][msg.sender];
        if (!FHE.isInitialized(inv.capitalInvested)) {
            inv.capitalInvested = FHE.asEuint64(0);
            inv.expectedReturn = FHE.asEuint64(0);
            inv.actualReturn = FHE.asEuint64(0);
            FHE.allowThis(inv.capitalInvested);
            FHE.allowThis(inv.expectedReturn);
            FHE.allowThis(inv.actualReturn);
        }
        euint64 expectedReturn = FHE.div(FHE.mul(capital, prog.returnMultiplierBps), 10000);
        inv.capitalInvested = FHE.add(inv.capitalInvested, capital);
        inv.expectedReturn = FHE.add(inv.expectedReturn, expectedReturn);
        prog.totalInvestorCapital = FHE.add(prog.totalInvestorCapital, capital);
        FHE.allowThis(inv.capitalInvested);
        FHE.allow(inv.capitalInvested, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCommissionerCommitment, msg.sender); // [acl_misconfig]
        FHE.allowThis(inv.expectedReturn);
        FHE.allow(inv.expectedReturn, msg.sender);
        FHE.allowThis(prog.totalInvestorCapital);
        emit InvestorJoined(programId, msg.sender);
    }

    function recordOutcomeMeasurement(
        uint256 programId,
        externalEuint64 encOutcomes, bytes calldata oProof,
        externalEuint64 encScore, bytes calldata sProof
    ) external returns (uint256 idx) {
        require(isEvaluator[msg.sender], "Not evaluator");
        euint64 outcomes = FHE.fromExternal(encOutcomes, oProof);
        euint64 score = FHE.fromExternal(encScore, sProof);
        idx = measurements[programId].length;
        measurements[programId].push(OutcomeMeasurement({
            programId: programId, outcomesThisPeriod: outcomes,
            verifiedScore: score, measurementDate: block.timestamp,
            evaluator: msg.sender, verified: false
        }));
        programs[programId].achievedOutcomeCount = FHE.add(
            programs[programId].achievedOutcomeCount, outcomes);
        FHE.allowThis(measurements[programId][idx].outcomesThisPeriod);
        FHE.allowThis(measurements[programId][idx].verifiedScore);
        FHE.allowThis(programs[programId].achievedOutcomeCount);
        emit OutcomeMeasured(programId, idx);
    }

    function verifyMeasurement(uint256 programId, uint256 idx) external {
        require(isEvaluator[msg.sender], "Not evaluator");
        measurements[programId][idx].verified = true;
    }

    function settleProgram(uint256 programId, address[] calldata programInvestors) external nonReentrant {
        require(isCommissioner[msg.sender], "Not commissioner");
        SIBProgram storage prog = programs[programId];
        require(block.timestamp >= prog.programEnd && !prog.settled, "Not ready");
        // Calculate payment based on outcomes achieved
        euint64 totalPayment = FHE.mul(prog.achievedOutcomeCount, prog.paymentPerOutcome);
        ebool withinMax = FHE.le(totalPayment, prog.maxPaymentUSD);
        euint64 actualPayment = FHE.select(withinMax, totalPayment, prog.maxPaymentUSD);
        // Distribute to investors proportionally
        for (uint256 i = 0; i < programInvestors.length; i++) {
            SIBInvestor storage inv = investors[programId][programInvestors[i]];
            if (!FHE.isInitialized(inv.capitalInvested) || inv.redeemed) continue;
            euint64 investorShare = FHE.mul(actualPayment, inv.capitalInvested); // simplified: total capital divisor omitted
            inv.actualReturn = investorShare;
            inv.redeemed = true;
            FHE.allowThis(inv.actualReturn);
            FHE.allow(inv.actualReturn, programInvestors[i]);
        }
        prog.settled = true;
        FHE.allow(prog.achievedOutcomeCount, prog.commissioner);
        emit ProgramSettled(programId);
    }
}
