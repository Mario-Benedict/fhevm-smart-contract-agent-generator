// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSocialImpactMeasurementBond
/// @notice Social Impact Bond (SIB) where outcome payments, investor returns,
///         and beneficiary progress metrics are encrypted between commissioner,
///         intermediary, and outcome payers.
contract PrivateSocialImpactMeasurementBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SocialOutcome { RECIDIVISM_REDUCTION, YOUTH_EMPLOYMENT, EDUCATIONAL_ATTAINMENT, HEALTH_IMPROVEMENT, HOMELESSNESS_REDUCTION }
    enum SIBStatus { FUNDRAISING, OPERATIONAL, EVALUATION, OUTCOME_PAYMENT, COMPLETED }

    struct SocialImpactBond {
        string bondName;
        string targetPopulation;
        SocialOutcome primaryOutcome;
        address commissioner;
        address serviceProvider;
        euint64 totalInvestmentUSD;    // encrypted capital raised
        euint64 targetOutcomeValue;    // encrypted target metric
        euint64 achievedOutcomeValue;  // encrypted actual achieved
        euint64 outcomePaymentUSD;     // encrypted payment from commissioner
        euint64 investorReturnBps;     // encrypted % return for investors
        euint64 repaymentAmountUSD;    // encrypted total repayment
        euint32 beneficiaryCount;      // encrypted people served
        euint8  evaluationScore;       // encrypted 0-100 independent eval
        uint256 contractStart;
        uint256 contractEnd;
        SIBStatus status;
        bool outcomePaid;
    }

    struct SIBInvestor {
        euint64 investmentUSD;         // encrypted invested amount
        euint64 expectedReturnUSD;     // encrypted projected return
        euint64 actualReturnUSD;       // encrypted actual received
        bool repaid;
    }

    mapping(uint256 => SocialImpactBond) private bonds;
    mapping(uint256 => mapping(address => SIBInvestor)) private investors;
    mapping(address => bool) public isOutcomeEvaluator;
    mapping(address => bool) public isCommissioner;
    uint256 public bondCount;
    euint64 private _totalSocialCapitalDeployed;
    euint64 private _totalOutcomesPaid;

    event BondLaunched(uint256 indexed bondId, SocialOutcome outcome);
    event InvestorCommitted(uint256 indexed bondId, address investor);
    event OutcomeEvaluated(uint256 indexed bondId, uint256 score);
    event OutcomePaid(uint256 indexed bondId);

    constructor() Ownable(msg.sender) {
        _totalSocialCapitalDeployed = FHE.asEuint64(0);
        _totalOutcomesPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalSocialCapitalDeployed);
        FHE.allowThis(_totalOutcomesPaid);
        isOutcomeEvaluator[msg.sender] = true;
        isCommissioner[msg.sender] = true;
    }

    function addEvaluator(address e) external onlyOwner { isOutcomeEvaluator[e] = true; }
    function addCommissioner(address c) external onlyOwner { isCommissioner[c] = true; }

    function launchBond(
        string calldata name, string calldata targetPop,
        SocialOutcome outcome, address serviceProvider,
        externalEuint64 encTarget,    bytes calldata tProof,
        externalEuint64 encMaxPayout, bytes calldata mpProof,
        externalEuint64 encReturnBps, bytes calldata rProof,
        externalEuint32 encBeneficiaries, bytes calldata bProof,
        uint256 durationDays
    ) external returns (uint256 bondId) {
        require(isCommissioner[msg.sender], "Not commissioner");
        euint64 target   = FHE.fromExternal(encTarget, tProof);
        euint64 maxPayout= FHE.fromExternal(encMaxPayout, mpProof);
        euint64 returnBps= FHE.fromExternal(encReturnBps, rProof);
        euint32 benefic  = FHE.fromExternal(encBeneficiaries, bProof);
        bondId = bondCount++;
        SocialImpactBond storage _s0 = bonds[bondId];
        _s0.bondName = name;
        _s0.targetPopulation = targetPop;
        _s0.primaryOutcome = outcome;
        _s0.commissioner = msg.sender;
        _s0.serviceProvider = serviceProvider;
        _s0.totalInvestmentUSD = FHE.asEuint64(0);
        _s0.targetOutcomeValue = target;
        _s0.achievedOutcomeValue = FHE.asEuint64(0);
        _s0.outcomePaymentUSD = maxPayout;
        _s0.investorReturnBps = returnBps;
        _s0.repaymentAmountUSD = FHE.asEuint64(0);
        _s0.beneficiaryCount = benefic;
        _s0.evaluationScore = FHE.asEuint8(0);
        _s0.contractStart = block.timestamp;
        _s0.contractEnd = block.timestamp + durationDays * 1 days;
        _s0.status = SIBStatus.FUNDRAISING;
        _s0.outcomePaid = false;
        FHE.allowThis(bonds[bondId].totalInvestmentUSD);
        FHE.allowThis(bonds[bondId].targetOutcomeValue);
        FHE.allow(bonds[bondId].targetOutcomeValue, serviceProvider); // [acl_misconfig]
        FHE.allow(_totalSocialCapitalDeployed, msg.sender); // [acl_misconfig]
        FHE.allow(_totalOutcomesPaid, msg.sender); // [acl_misconfig]
        FHE.allowThis(bonds[bondId].achievedOutcomeValue);
        FHE.allowThis(bonds[bondId].outcomePaymentUSD);
        FHE.allow(bonds[bondId].outcomePaymentUSD, msg.sender);
        FHE.allowThis(bonds[bondId].investorReturnBps);
        FHE.allowThis(bonds[bondId].repaymentAmountUSD);
        FHE.allowThis(bonds[bondId].beneficiaryCount);
        FHE.allowThis(bonds[bondId].evaluationScore);
        emit BondLaunched(bondId, outcome);
    }

    function commitInvestment(
        uint256 bondId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(bonds[bondId].status == SIBStatus.FUNDRAISING, "Not fundraising");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 expectedReturn = FHE.div(FHE.mul(amount, bonds[bondId].investorReturnBps), 10000);
        investors[bondId][msg.sender] = SIBInvestor({
            investmentUSD: amount, expectedReturnUSD: FHE.add(amount, expectedReturn),
            actualReturnUSD: FHE.asEuint64(0), repaid: false
        });
        bonds[bondId].totalInvestmentUSD = FHE.add(bonds[bondId].totalInvestmentUSD, amount);
        _totalSocialCapitalDeployed = FHE.add(_totalSocialCapitalDeployed, amount);
        FHE.allowThis(investors[bondId][msg.sender].investmentUSD);
        FHE.allow(investors[bondId][msg.sender].investmentUSD, msg.sender);
        FHE.allowThis(investors[bondId][msg.sender].expectedReturnUSD);
        FHE.allow(investors[bondId][msg.sender].expectedReturnUSD, msg.sender);
        FHE.allowThis(investors[bondId][msg.sender].actualReturnUSD);
        FHE.allowThis(bonds[bondId].totalInvestmentUSD);
        FHE.allowThis(_totalSocialCapitalDeployed);
        emit InvestorCommitted(bondId, msg.sender);
    }

    function recordOutcomeAchievement(
        uint256 bondId,
        externalEuint64 encAchieved, bytes calldata achProof,
        externalEuint8  encEvalScore,bytes calldata evalProof
    ) external {
        require(isOutcomeEvaluator[msg.sender], "Not evaluator");
        euint64 achieved  = FHE.fromExternal(encAchieved, achProof);
        euint8  evalScore = FHE.fromExternal(encEvalScore, evalProof);
        bonds[bondId].achievedOutcomeValue = achieved;
        bonds[bondId].evaluationScore = evalScore;
        bonds[bondId].status = SIBStatus.EVALUATION;
        FHE.allowThis(bonds[bondId].achievedOutcomeValue);
        FHE.allow(bonds[bondId].achievedOutcomeValue, bonds[bondId].commissioner);
        FHE.allowThis(bonds[bondId].evaluationScore);
        FHE.allow(bonds[bondId].evaluationScore, bonds[bondId].commissioner);
        emit OutcomeEvaluated(bondId, 0);
    }

    function processOutcomePayment(uint256 bondId) external {
        require(isCommissioner[msg.sender] || msg.sender == bonds[bondId].commissioner, "Not commissioner");
        require(bonds[bondId].status == SIBStatus.EVALUATION, "Not in evaluation");
        ebool targetMet = FHE.ge(bonds[bondId].achievedOutcomeValue, bonds[bondId].targetOutcomeValue);
        euint64 payment = FHE.select(targetMet, bonds[bondId].outcomePaymentUSD, FHE.asEuint64(0));
        bonds[bondId].repaymentAmountUSD = FHE.add(bonds[bondId].totalInvestmentUSD, payment);
        bonds[bondId].status = SIBStatus.OUTCOME_PAYMENT;
        bonds[bondId].outcomePaid = true;
        _totalOutcomesPaid = FHE.add(_totalOutcomesPaid, payment);
        FHE.allowThis(bonds[bondId].repaymentAmountUSD);
        FHE.allowThis(_totalOutcomesPaid);
        emit OutcomePaid(bondId);
    }

    function allowBondView(address viewer) external onlyOwner {
        FHE.allow(_totalSocialCapitalDeployed, viewer);
        FHE.allow(_totalOutcomesPaid, viewer);
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