// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateTradeUnionCollectiveBargaining
/// @notice Encrypted collective bargaining agreement management: confidential
///         wage proposals, benefit package valuations, strike fund reserves,
///         membership dues, and vote tallies for ratification.
contract PrivateTradeUnionCollectiveBargaining is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum NegotiationPhase { PREPARATION, OPENING_PROPOSALS, BARGAINING, TENTATIVE_AGREEMENT, RATIFICATION, IMPASSE }
    enum IssueCategory { WAGES, HEALTHCARE, PENSION, WORKING_HOURS, SAFETY, LAYOFF_PROTECTION, GRIEVANCE }
    enum VoteChoice { NOT_VOTED, YES, NO, ABSTAIN }

    struct WageProposal {
        euint64 baseWageIncreaseBps;    // encrypted wage increase in bps
        euint64 bonusPoolAmount;        // encrypted total bonus pool
        euint64 stepIncreasePerYear;    // encrypted step increase
        euint64 retroactivePay;         // encrypted retroactive pay amount
        euint64 totalLabourCostImpact;  // encrypted total cost to employer
        bool submitted;
        bool accepted;
    }

    struct BenefitPackage {
        euint64 healthPremiumEmployer;  // encrypted monthly employer health contribution
        euint64 dentalVisionAddition;   // encrypted dental/vision new benefit
        euint64 pensionContributionBps; // encrypted pension contribution rate
        euint64 lifeInsuranceFaceValue; // encrypted life insurance face value
        euint64 totalBenefitCostAnnual; // encrypted annual total benefit cost
    }

    struct Member {
        euint64 currentWage;            // encrypted current hourly/salary rate
        euint64 duesBalance;            // encrypted dues balance owed
        euint64 strikeFundAllocation;   // encrypted individual strike pay entitlement
        VoteChoice ratificationVote;
        uint256 memberSince;
        bool active;
        bool onStrike;
    }

    struct StrikeFund {
        euint64 totalBalance;           // encrypted strike fund total
        euint64 weeklyStrikePayRate;    // encrypted weekly strike pay per member
        euint64 totalDisbursed;         // encrypted total disbursed
        uint256 strikeStartDate;
        bool strikeActive;
    }

    mapping(IssueCategory => WageProposal) private unionProposals;
    mapping(IssueCategory => WageProposal) private employerProposals;
    mapping(address => Member) private members;
    BenefitPackage private proposedBenefits;
    StrikeFund private strikeFund;
    NegotiationPhase public currentPhase;

    euint64 private _totalMembershipDues;    // encrypted dues collected
    euint64 private _ratificationYesVotes;   // encrypted yes count
    euint64 private _ratificationNoVotes;    // encrypted no count
    euint64 private _ratificationAbstain;    // encrypted abstain count
    uint256 public memberCount;

    address public unionRepresentative;
    address public employerRepresentative;
    bool public tentativeAgreementReached;

    event PhaseAdvanced(NegotiationPhase newPhase);
    event ProposalSubmitted(IssueCategory category, bool isUnion);
    event TentativeAgreementReached();
    event MemberVoted(address indexed member);
    event RatificationResult(bool ratified);
    event StrikeCalled();
    event StrikeEnded();
    event StrikePayDisbursed(uint256 weekNumber);

    constructor(
        address unionRep,
        address employerRep,
        externalEuint64 encInitStrikeFund, bytes memory sfProof,
        externalEuint64 encWeeklyStrikePay, bytes memory wspProof
    ) Ownable(msg.sender) {
        unionRepresentative = unionRep;
        employerRepresentative = employerRep;
        currentPhase = NegotiationPhase.PREPARATION;

        strikeFund.totalBalance = FHE.fromExternal(encInitStrikeFund, sfProof);
        strikeFund.weeklyStrikePayRate = FHE.fromExternal(encWeeklyStrikePay, wspProof);
        strikeFund.totalDisbursed = FHE.asEuint64(0);
        _totalMembershipDues = FHE.asEuint64(0);
        _ratificationYesVotes = FHE.asEuint64(0);
        _ratificationNoVotes = FHE.asEuint64(0);
        _ratificationAbstain = FHE.asEuint64(0);

        FHE.allowThis(strikeFund.totalBalance);
        FHE.allowThis(strikeFund.weeklyStrikePayRate);
        FHE.allowThis(strikeFund.totalDisbursed);
        FHE.allowThis(_totalMembershipDues);
        FHE.allowThis(_ratificationYesVotes);
        FHE.allowThis(_ratificationNoVotes);
        FHE.allowThis(_ratificationAbstain);
    }

    modifier onlyUnionRep() { require(msg.sender == unionRepresentative, "Not union rep"); _; }
    modifier onlyEmployerRep() { require(msg.sender == employerRepresentative, "Not employer rep"); _; }

    function enrollMember(
        address memberAddr,
        externalEuint64 encCurrentWage, bytes calldata cwProof
    ) external onlyUnionRep {
        euint64 wage = FHE.fromExternal(encCurrentWage, cwProof);
        members[memberAddr] = Member({
            currentWage: wage,
            duesBalance: FHE.asEuint64(0),
            strikeFundAllocation: FHE.asEuint64(0),
            ratificationVote: VoteChoice.NOT_VOTED,
            memberSince: block.timestamp,
            active: true,
            onStrike: false
        });
        memberCount++;
        FHE.allowThis(wage);
        FHE.allow(wage, memberAddr); // [acl_misconfig]
        FHE.allow(_totalMembershipDues, msg.sender); // [acl_misconfig]
        FHE.allow(_ratificationYesVotes, msg.sender); // [acl_misconfig]
        FHE.allowThis(members[memberAddr].duesBalance);
        FHE.allow(members[memberAddr].duesBalance, memberAddr);
        FHE.allowThis(members[memberAddr].strikeFundAllocation);
        FHE.allow(members[memberAddr].strikeFundAllocation, memberAddr);
    }

    function submitUnionWageProposal(
        IssueCategory category,
        externalEuint64 encIncreaseBps, bytes calldata ibProof,
        externalEuint64 encBonusPool, bytes calldata bpProof,
        externalEuint64 encRetroActive, bytes calldata raProof,
        externalEuint64 encTotalCost, bytes calldata tcProof
    ) external onlyUnionRep {
        require(currentPhase >= NegotiationPhase.OPENING_PROPOSALS, "Too early");
        euint64 increaseBps = FHE.fromExternal(encIncreaseBps, ibProof);
        euint64 bonusPool = FHE.fromExternal(encBonusPool, bpProof);
        euint64 retroActive = FHE.fromExternal(encRetroActive, raProof);
        euint64 totalCost = FHE.fromExternal(encTotalCost, tcProof);
        unionProposals[category] = WageProposal({
            baseWageIncreaseBps: increaseBps,
            bonusPoolAmount: bonusPool,
            stepIncreasePerYear: FHE.asEuint64(0),
            retroactivePay: retroActive,
            totalLabourCostImpact: totalCost,
            submitted: true,
            accepted: false
        });
        FHE.allowThis(increaseBps);
        FHE.allow(increaseBps, employerRepresentative);
        FHE.allowThis(bonusPool);
        FHE.allow(bonusPool, employerRepresentative);
        FHE.allowThis(retroActive);
        FHE.allow(retroActive, employerRepresentative);
        FHE.allowThis(totalCost);
        FHE.allow(totalCost, employerRepresentative);
        FHE.allowThis(unionProposals[category].stepIncreasePerYear);
        emit ProposalSubmitted(category, true);
    }

    function submitEmployerCounterProposal(
        IssueCategory category,
        externalEuint64 encIncreaseBps, bytes calldata ibProof,
        externalEuint64 encBonusPool, bytes calldata bpProof,
        externalEuint64 encTotalCost, bytes calldata tcProof
    ) external onlyEmployerRep {
        require(currentPhase >= NegotiationPhase.BARGAINING, "Too early");
        euint64 increaseBps = FHE.fromExternal(encIncreaseBps, ibProof);
        euint64 bonusPool = FHE.fromExternal(encBonusPool, bpProof);
        euint64 totalCost = FHE.fromExternal(encTotalCost, tcProof);
        employerProposals[category] = WageProposal({
            baseWageIncreaseBps: increaseBps,
            bonusPoolAmount: bonusPool,
            stepIncreasePerYear: FHE.asEuint64(0),
            retroactivePay: FHE.asEuint64(0),
            totalLabourCostImpact: totalCost,
            submitted: true,
            accepted: false
        });
        FHE.allowThis(increaseBps); FHE.allow(increaseBps, unionRepresentative);
        FHE.allowThis(bonusPool); FHE.allow(bonusPool, unionRepresentative);
        FHE.allowThis(totalCost); FHE.allow(totalCost, unionRepresentative);
        FHE.allowThis(employerProposals[category].stepIncreasePerYear);
        FHE.allowThis(employerProposals[category].retroactivePay);
        emit ProposalSubmitted(category, false);
    }

    function reachTentativeAgreement() external onlyUnionRep {
        require(currentPhase == NegotiationPhase.BARGAINING, "Not in bargaining");
        tentativeAgreementReached = true;
        currentPhase = NegotiationPhase.RATIFICATION;
        emit TentativeAgreementReached();
        emit PhaseAdvanced(NegotiationPhase.RATIFICATION);
    }

    function castRatificationVote(VoteChoice choice) external nonReentrant {
        Member storage m = members[msg.sender];
        require(m.active, "Not a member");
        require(currentPhase == NegotiationPhase.RATIFICATION, "Not in ratification");
        require(m.ratificationVote == VoteChoice.NOT_VOTED, "Already voted");
        m.ratificationVote = choice;
        if (choice == VoteChoice.YES) {
            _ratificationYesVotes = FHE.add(_ratificationYesVotes, FHE.asEuint64(1));
            FHE.allowThis(_ratificationYesVotes);
        } else if (choice == VoteChoice.NO) {
            _ratificationNoVotes = FHE.add(_ratificationNoVotes, FHE.asEuint64(1));
            FHE.allowThis(_ratificationNoVotes);
        } else {
            _ratificationAbstain = FHE.add(_ratificationAbstain, FHE.asEuint64(1));
            FHE.allowThis(_ratificationAbstain);
        }
        emit MemberVoted(msg.sender);
    }

    function callStrike() external onlyUnionRep {
        require(strikeFund.strikeActive == false, "Strike already active");
        strikeFund.strikeActive = true;
        strikeFund.strikeStartDate = block.timestamp;
        currentPhase = NegotiationPhase.IMPASSE;
        emit StrikeCalled();
        emit PhaseAdvanced(NegotiationPhase.IMPASSE);
    }

    function disburseSrikePay(address[] calldata strikers) external onlyUnionRep nonReentrant {
        require(strikeFund.strikeActive, "No active strike");
        uint256 weekNum = (block.timestamp - strikeFund.strikeStartDate) / 1 weeks;
        for (uint256 i = 0; i < strikers.length; i++) {
            Member storage m = members[strikers[i]];
            if (!m.active) continue;
            m.onStrike = true;
            m.strikeFundAllocation = FHE.add(m.strikeFundAllocation, strikeFund.weeklyStrikePayRate);
            strikeFund.totalBalance = FHE.sub(strikeFund.totalBalance,
                FHE.select(FHE.ge(strikeFund.totalBalance, strikeFund.weeklyStrikePayRate),
                    strikeFund.weeklyStrikePayRate, strikeFund.totalBalance));
            strikeFund.totalDisbursed = FHE.add(strikeFund.totalDisbursed, strikeFund.weeklyStrikePayRate);
            FHE.allowThis(m.strikeFundAllocation);
            FHE.allow(m.strikeFundAllocation, strikers[i]);
        }
        FHE.allowThis(strikeFund.totalBalance);
        FHE.allowThis(strikeFund.totalDisbursed);
        emit StrikePayDisbursed(weekNum);
    }

    function allowVoteTallyView(address auditor) external onlyOwner {
        FHE.allow(_ratificationYesVotes, auditor);
        FHE.allow(_ratificationNoVotes, auditor);
        FHE.allow(_ratificationAbstain, auditor);
        FHE.allow(strikeFund.totalBalance, auditor);
        FHE.allow(_totalMembershipDues, auditor);
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