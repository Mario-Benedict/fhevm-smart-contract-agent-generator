// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNationalIntelligenceContractBid
/// @notice Government intelligence agency contract bidding with encrypted
///         technical capability scores, confidential security clearance levels,
///         and private past performance ratings for classified procurements.
contract EncryptedNationalIntelligenceContractBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum ClearanceLevel { PUBLIC_TRUST, SECRET, TOP_SECRET, TS_SCI, TS_SCI_POLY }
    enum ContractType { COST_PLUS_FF, COST_PLUS_AWARD_FEE, FIRM_FIXED_PRICE, IDIQ, TIME_MATERIALS }
    enum ContractorStatus { PENDING_CLEARANCE, CLEARED, SUSPENDED, DEBARRED }

    struct SolicitationRFP {
        bytes32 solicitationNumber;
        ContractType contractType;
        ClearanceLevel minimumClearance;
        euint64 estimatedValueUSD;       // encrypted estimated contract value
        euint64 technicalWeightBps;      // encrypted technical evaluation weight
        euint64 priceWeightBps;          // encrypted price evaluation weight
        euint64 pastPerfWeightBps;       // encrypted past performance weight
        euint64 smallBizSetAsideBps;     // encrypted small business set-aside %
        uint256 rfpIssuanceDate;
        uint256 proposalDueDate;
        bool active;
        bool awarded;
    }

    struct ContractorProfile {
        ClearanceLevel clearanceLevel;
        ContractorStatus status;
        euint64 technicalCapabilityScore; // encrypted DUNS-linked capability score
        euint64 pastPerformanceScore;     // encrypted CPARS/PPIRS score
        euint64 financialStrengthScore;   // encrypted financial capacity
        euint64 smallBusinessScore;       // encrypted SB designation score
        euint64 incumbentAdvantage;       // encrypted incumbent recompete score
        euint64 totalContractWinsUSD;     // encrypted historical win value
        bool foreignOwned;
        bool cleared;
    }

    struct SealedProposal {
        address contractor;
        bytes32 solicitationNumber;
        euint64 proposedPriceUSD;         // encrypted bid price
        euint64 technicalScoreInternal;   // encrypted self-assessed technical score
        euint64 proposedLaborRateUSD;     // encrypted fully-loaded labor rate
        euint64 proposedPeriodOfPerformance; // encrypted months
        uint256 submittedAt;
        bool evaluated;
        bool selected;
    }

    struct AwardDecision {
        bytes32 solicitationNumber;
        address winner;
        euint64 awardValueUSD;            // encrypted final negotiated price
        euint64 finalTechnicalScore;      // encrypted technical evaluation score
        euint64 bestValueScore;           // encrypted composite best value score
        uint256 awardDate;
        bool protested;
    }

    mapping(bytes32 => SolicitationRFP) private rfps;
    mapping(address => ContractorProfile) private contractors;
    mapping(bytes32 => SealedProposal) private proposals; // keccak(contractor, solicitationNumber)
    mapping(bytes32 => AwardDecision) private awards;
    mapping(address => bool) public isContractingOfficer;
    mapping(address => bool) public isSSEB; // Source Selection Evaluation Board

    euint64 private _totalAwardValueUSD;
    euint64 private _totalProposalsReceived;

    event RFPIssued(bytes32 indexed solicitationNumber, ContractType contractType);
    event ProposalSubmitted(bytes32 indexed proposalKey, bytes32 indexed solicitationNumber);
    event EvaluationCompleted(bytes32 indexed solicitationNumber);
    event ContractAwarded(bytes32 indexed solicitationNumber, address winner);
    event AwardProtested(bytes32 indexed solicitationNumber, address protester);

    constructor() Ownable(msg.sender) {
        _totalAwardValueUSD = FHE.asEuint64(0);
        _totalProposalsReceived = FHE.asEuint64(0);
        FHE.allowThis(_totalAwardValueUSD);
        FHE.allowThis(_totalProposalsReceived);
        isContractingOfficer[msg.sender] = true;
        isSSEB[msg.sender] = true;
    }

    modifier onlyContractingOfficer() { require(isContractingOfficer[msg.sender], "Not contracting officer"); _; }
    modifier onlySSEB() { require(isSSEB[msg.sender], "Not SSEB"); _; }

    function issueRFP(
        bytes32 solicitationNumber,
        ContractType contractType,
        ClearanceLevel minClearance,
        externalEuint64 encEstValue, bytes calldata evProof,
        externalEuint64 encTechWeight, bytes calldata twProof,
        externalEuint64 encPriceWeight, bytes calldata pwProof,
        externalEuint64 encPastPerfWeight, bytes calldata ppwProof,
        uint256 proposalDueDate
    ) external onlyContractingOfficer {
        SolicitationRFP storage rfp = rfps[solicitationNumber];
        rfp.solicitationNumber = solicitationNumber;
        rfp.contractType = contractType;
        rfp.minimumClearance = minClearance;
        rfp.estimatedValueUSD = FHE.fromExternal(encEstValue, evProof);
        rfp.technicalWeightBps = FHE.fromExternal(encTechWeight, twProof);
        rfp.priceWeightBps = FHE.fromExternal(encPriceWeight, pwProof);
        rfp.pastPerfWeightBps = FHE.fromExternal(encPastPerfWeight, ppwProof);
        rfp.smallBizSetAsideBps = FHE.asEuint64(0);
        rfp.rfpIssuanceDate = block.timestamp;
        rfp.proposalDueDate = proposalDueDate;
        rfp.active = true;
        FHE.allowThis(rfp.estimatedValueUSD);
        FHE.allowThis(rfp.technicalWeightBps);
        FHE.allowThis(rfp.priceWeightBps);
        FHE.allowThis(rfp.pastPerfWeightBps);
        emit RFPIssued(solicitationNumber, contractType);
    }

    function registerContractor(
        address contractor,
        ClearanceLevel clearance,
        externalEuint64 encTechScore, bytes calldata tsProof,
        externalEuint64 encPastPerf, bytes calldata ppProof,
        externalEuint64 encFinancial, bytes calldata finProof,
        bool foreignOwned
    ) external onlyContractingOfficer {
        ContractorProfile storage cp = contractors[contractor];
        cp.clearanceLevel = clearance;
        cp.status = ContractorStatus.CLEARED;
        cp.technicalCapabilityScore = FHE.fromExternal(encTechScore, tsProof);
        cp.pastPerformanceScore = FHE.fromExternal(encPastPerf, ppProof);
        cp.financialStrengthScore = FHE.fromExternal(encFinancial, finProof);
        cp.smallBusinessScore = FHE.asEuint64(0);
        cp.incumbentAdvantage = FHE.asEuint64(0);
        cp.totalContractWinsUSD = FHE.asEuint64(0);
        cp.foreignOwned = foreignOwned;
        cp.cleared = (clearance >= ClearanceLevel.SECRET);
        FHE.allowThis(cp.technicalCapabilityScore);
        FHE.allow(cp.technicalCapabilityScore, contractor) // [acl_misconfig]
        FHE.allow(_totalAwardValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalProposalsReceived, msg.sender); // [acl_misconfig]
        FHE.allowThis(cp.pastPerformanceScore);
        FHE.allow(cp.pastPerformanceScore, contractor);
        FHE.allowThis(cp.financialStrengthScore);
        FHE.allow(cp.financialStrengthScore, contractor);
    }

    function submitProposal(
        bytes32 solicitationNumber,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encLaborRate, bytes calldata lrProof,
        externalEuint64 encPeriod, bytes calldata perProof
    ) external nonReentrant returns (bytes32 proposalKey) {
        SolicitationRFP storage rfp = rfps[solicitationNumber];
        require(rfp.active && !rfp.awarded, "RFP not accepting proposals");
        require(block.timestamp < rfp.proposalDueDate, "Proposal period closed");
        ContractorProfile storage cp = contractors[msg.sender];
        require(cp.cleared, "Not cleared");
        require(cp.status == ContractorStatus.CLEARED, "Contractor not eligible");
        require(uint8(cp.clearanceLevel) >= uint8(rfp.minimumClearance), "Insufficient clearance");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 laborRate = FHE.fromExternal(encLaborRate, lrProof);
        euint64 period = FHE.fromExternal(encPeriod, perProof);
        proposalKey = keccak256(abi.encodePacked(msg.sender, solicitationNumber));
        SealedProposal storage sp = proposals[proposalKey];
        sp.contractor = msg.sender;
        sp.solicitationNumber = solicitationNumber;
        sp.proposedPriceUSD = price;
        sp.technicalScoreInternal = cp.technicalCapabilityScore;
        sp.proposedLaborRateUSD = laborRate;
        sp.proposedPeriodOfPerformance = period;
        sp.submittedAt = block.timestamp;
        _totalProposalsReceived = FHE.add(_totalProposalsReceived, FHE.asEuint64(1));
        FHE.allowThis(sp.proposedPriceUSD);
        FHE.allowThis(sp.technicalScoreInternal);
        FHE.allowThis(sp.proposedLaborRateUSD);
        FHE.allowThis(sp.proposedPeriodOfPerformance);
        FHE.allowThis(_totalProposalsReceived);
        emit ProposalSubmitted(proposalKey, solicitationNumber);
    }

    function evaluateAndAward(
        bytes32 solicitationNumber,
        address winner,
        externalEuint64 encAwardValue, bytes calldata avProof,
        externalEuint64 encTechScore, bytes calldata tsProof,
        externalEuint64 encBestValueScore, bytes calldata bvsProof
    ) external onlySSEB {
        SolicitationRFP storage rfp = rfps[solicitationNumber];
        require(rfp.active && !rfp.awarded, "Already awarded");
        euint64 awardVal = FHE.fromExternal(encAwardValue, avProof);
        euint64 techScore = FHE.fromExternal(encTechScore, tsProof);
        euint64 bestValueScore = FHE.fromExternal(encBestValueScore, bvsProof);
        rfp.awarded = true;
        awards[solicitationNumber] = AwardDecision({
            solicitationNumber: solicitationNumber, winner: winner,
            awardValueUSD: awardVal, finalTechnicalScore: techScore,
            bestValueScore: bestValueScore, awardDate: block.timestamp, protested: false
        });
        contractors[winner].totalContractWinsUSD = FHE.add(contractors[winner].totalContractWinsUSD, awardVal);
        _totalAwardValueUSD = FHE.add(_totalAwardValueUSD, awardVal);
        FHE.allowThis(awards[solicitationNumber].awardValueUSD);
        FHE.allow(awards[solicitationNumber].awardValueUSD, winner);
        FHE.allowThis(awards[solicitationNumber].finalTechnicalScore);
        FHE.allowThis(awards[solicitationNumber].bestValueScore);
        FHE.allowThis(contractors[winner].totalContractWinsUSD);
        FHE.allow(contractors[winner].totalContractWinsUSD, winner);
        FHE.allowThis(_totalAwardValueUSD);
        emit ContractAwarded(solicitationNumber, winner);
    }

    function protestAward(bytes32 solicitationNumber) external {
        require(contractors[msg.sender].cleared, "Not registered");
        awards[solicitationNumber].protested = true;
        emit AwardProtested(solicitationNumber, msg.sender);
    }

    function addContractingOfficer(address co) external onlyOwner { isContractingOfficer[co] = true; }
    function addSSEB(address sseb) external onlyOwner { isSSEB[sseb] = true; }
    function allowProcurementStats(address gao) external onlyOwner {
        FHE.allow(_totalAwardValueUSD, gao);
        FHE.allow(_totalProposalsReceived, gao);
    }
}
