// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCorporateMAndADueDiligence
/// @notice M&A transaction management with encrypted deal valuations, synergy estimates,
///         board approval thresholds, and regulatory filing scores.
contract EncryptedCorporateMAndADueDiligence is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DealType { STRATEGIC_ACQUISITION, MERGER_OF_EQUALS, LEVERAGED_BUYOUT, CARVE_OUT, REVERSE_MERGER }
    enum DealStatus { EXPLORATORY, NDA_SIGNED, DUE_DILIGENCE, NEGOTIATION, SIGNED, REGULATORY_REVIEW, CLOSED, FAILED }

    struct MAndADeal {
        string targetCompany;
        string acquirerCompany;
        DealType dealType;
        address targetRep;
        address acquirerRep;
        euint64 indicativeValueUSD;    // encrypted EV
        euint64 offerPricePerShareUSD; // encrypted bid price
        euint64 premiumToBVBps;        // encrypted premium over book value
        euint64 synergiesEstimateUSD;  // encrypted synergies NPV
        euint64 breakupFeeUSD;         // encrypted reverse break-up fee
        euint64 deferredConsideration; // encrypted earnout amount
        euint32 targetSharesOutstanding; // encrypted float
        euint8  antitTrustRiskScore;   // encrypted regulatory risk 0-100
        euint8  integraitonComplexity; // encrypted 0-100
        DealStatus status;
        uint256 announcementDate;
        uint256 expectedCloseDate;
    }

    struct DDWorkstream {
        string workstreamName;
        euint8  completionPct;         // encrypted % complete
        euint8  riskScore;             // encrypted red flags 0-100
        euint64 adjustmentToValuation; // encrypted DD adjustment
        address leadAdvisor;
        bool complete;
    }

    mapping(uint256 => MAndADeal) private deals;
    mapping(uint256 => mapping(uint256 => DDWorkstream)) private workstreams;
    mapping(uint256 => uint256) private workstreamCounts;
    mapping(address => bool) public isInvestmentBanker;
    mapping(address => bool) public isLegalCounsel;
    uint256 public dealCount;
    euint64 private _totalDealValueManaged;
    euint64 private _totalSynergiesIdentified;

    event DealInitiated(uint256 indexed dealId, DealType dType, string target);
    event WorkstreamAdded(uint256 indexed dealId, uint256 wsId, string name);
    event DealStatusUpdated(uint256 indexed dealId, DealStatus newStatus);
    event DealClosed(uint256 indexed dealId);
    event DealFailed(uint256 indexed dealId);

    constructor() Ownable(msg.sender) {
        _totalDealValueManaged = FHE.asEuint64(0);
        _totalSynergiesIdentified = FHE.asEuint64(0);
        FHE.allowThis(_totalDealValueManaged);
        FHE.allowThis(_totalSynergiesIdentified);
        isInvestmentBanker[msg.sender] = true;
    }

    function addBanker(address b) external onlyOwner { isInvestmentBanker[b] = true; }
    function addLegalCounsel(address l) external onlyOwner { isLegalCounsel[l] = true; }

    function initiateDeal(
        string calldata target,
        string calldata acquirer,
        DealType dType,
        address targetRep,
        externalEuint64 encIndicativeVal, bytes calldata ivProof,
        externalEuint64 encOfferPrice,    bytes calldata opProof,
        externalEuint64 encSynergies,     bytes calldata synProof,
        externalEuint64 encBreakupFee,    bytes calldata bfProof,
        externalEuint8  encAntitrust,     bytes calldata atProof,
        uint256 expectedCloseDays
    ) external returns (uint256 dealId) {
        require(isInvestmentBanker[msg.sender], "Not banker");
        euint64 indicVal  = FHE.fromExternal(encIndicativeVal, ivProof);
        euint64 offerPric = FHE.fromExternal(encOfferPrice, opProof);
        euint64 synergies = FHE.fromExternal(encSynergies, synProof);
        euint64 breakupFee= FHE.fromExternal(encBreakupFee, bfProof);
        euint8  antitrust = FHE.fromExternal(encAntitrust, atProof);
        dealId = dealCount++;
        deals[dealId] = MAndADeal({
            targetCompany: target, acquirerCompany: acquirer, dealType: dType,
            targetRep: targetRep, acquirerRep: msg.sender,
            indicativeValueUSD: indicVal, offerPricePerShareUSD: offerPric,
            premiumToBVBps: FHE.asEuint64(0), synergiesEstimateUSD: synergies,
            breakupFeeUSD: breakupFee, deferredConsideration: FHE.asEuint64(0),
            targetSharesOutstanding: FHE.asEuint32(0),
            antitTrustRiskScore: antitrust, integraitonComplexity: FHE.asEuint8(50),
            status: DealStatus.EXPLORATORY,
            announcementDate: block.timestamp,
            expectedCloseDate: block.timestamp + expectedCloseDays * 1 days
        });
        _totalDealValueManaged = FHE.add(_totalDealValueManaged, indicVal);
        _totalSynergiesIdentified = FHE.add(_totalSynergiesIdentified, synergies);
        FHE.allowThis(deals[dealId].indicativeValueUSD);
        FHE.allow(deals[dealId].indicativeValueUSD, targetRep);
        FHE.allow(deals[dealId].indicativeValueUSD, msg.sender);
        FHE.allowThis(deals[dealId].offerPricePerShareUSD);
        FHE.allow(deals[dealId].offerPricePerShareUSD, targetRep);
        FHE.allowThis(deals[dealId].synergiesEstimateUSD);
        FHE.allow(deals[dealId].synergiesEstimateUSD, msg.sender);
        FHE.allowThis(deals[dealId].breakupFeeUSD);
        FHE.allow(deals[dealId].breakupFeeUSD, targetRep);
        FHE.allow(deals[dealId].breakupFeeUSD, msg.sender);
        FHE.allowThis(deals[dealId].antitTrustRiskScore);
        FHE.allow(deals[dealId].antitTrustRiskScore, msg.sender);
        FHE.allowThis(deals[dealId].premiumToBVBps);
        FHE.allowThis(deals[dealId].deferredConsideration);
        FHE.allowThis(deals[dealId].targetSharesOutstanding);
        FHE.allowThis(deals[dealId].integraitonComplexity);
        FHE.allowThis(_totalDealValueManaged);
        FHE.allowThis(_totalSynergiesIdentified);
        emit DealInitiated(dealId, dType, target);
    }

    function addDDWorkstream(
        uint256 dealId,
        string calldata wsName,
        address leadAdvisor,
        externalEuint64 encValAdj, bytes calldata vaProof
    ) external returns (uint256 wsId) {
        require(isInvestmentBanker[msg.sender] || isLegalCounsel[msg.sender], "Unauthorized");
        euint64 valAdj = FHE.fromExternal(encValAdj, vaProof);
        wsId = workstreamCounts[dealId]++;
        workstreams[dealId][wsId] = DDWorkstream({
            workstreamName: wsName,
            completionPct: FHE.asEuint8(0),
            riskScore: FHE.asEuint8(0),
            adjustmentToValuation: valAdj,
            leadAdvisor: leadAdvisor,
            complete: false
        });
        FHE.allowThis(workstreams[dealId][wsId].completionPct);
        FHE.allow(workstreams[dealId][wsId].completionPct, leadAdvisor);
        FHE.allowThis(workstreams[dealId][wsId].riskScore);
        FHE.allow(workstreams[dealId][wsId].riskScore, msg.sender);
        FHE.allowThis(workstreams[dealId][wsId].adjustmentToValuation);
        FHE.allow(workstreams[dealId][wsId].adjustmentToValuation, msg.sender);
        emit WorkstreamAdded(dealId, wsId, wsName);
    }

    function updateWorkstream(
        uint256 dealId, uint256 wsId,
        externalEuint8 encCompletion, bytes calldata compProof,
        externalEuint8 encRisk,       bytes calldata riskProof
    ) external {
        require(workstreams[dealId][wsId].leadAdvisor == msg.sender || isInvestmentBanker[msg.sender], "Unauthorized");
        workstreams[dealId][wsId].completionPct = FHE.fromExternal(encCompletion, compProof);
        workstreams[dealId][wsId].riskScore = FHE.fromExternal(encRisk, riskProof);
        FHE.allowThis(workstreams[dealId][wsId].completionPct);
        FHE.allowThis(workstreams[dealId][wsId].riskScore);
    }

    function updateDealStatus(uint256 dealId, DealStatus newStatus) external {
        require(isInvestmentBanker[msg.sender], "Not banker");
        deals[dealId].status = newStatus;
        emit DealStatusUpdated(dealId, newStatus);
        if (newStatus == DealStatus.CLOSED) emit DealClosed(dealId);
        if (newStatus == DealStatus.FAILED) emit DealFailed(dealId);
    }

    function allowDealView(uint256 dealId, address viewer) external {
        require(isInvestmentBanker[msg.sender], "Not banker");
        FHE.allow(deals[dealId].indicativeValueUSD, viewer);
        FHE.allow(deals[dealId].synergiesEstimateUSD, viewer);
    }
}
