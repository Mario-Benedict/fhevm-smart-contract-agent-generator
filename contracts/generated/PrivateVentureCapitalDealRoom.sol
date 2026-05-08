// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateVentureCapitalDealRoom
/// @notice VC deal room where portfolio companies submit encrypted financials,
///         VC partners vote with encrypted conviction scores, encrypted terms negotiated.
contract PrivateVentureCapitalDealRoom is ZamaEthereumConfig, Ownable {
    enum DealStage { Screening, DueDiligence, TermSheet, Closed, Passed }

    struct Deal {
        string companyName;
        string sector;
        euint64 requestedAmount;     // encrypted funding ask
        euint64 preMoneyValuation;   // encrypted pre-money val
        euint64 revenueARR;          // encrypted annual recurring revenue
        euint64 burnRateMonthly;     // encrypted monthly burn
        euint64 partnerVoteScore;    // encrypted aggregate conviction score
        uint8 partnerVoteCount;
        DealStage stage;
        address dealLead;
        uint256 submittedAt;
    }

    struct PartnerVote {
        euint8 convictionScore;   // encrypted 1-10
        euint64 proposedTerms;    // encrypted check size
        bool voted;
    }

    mapping(uint256 => Deal) private deals;
    mapping(uint256 => mapping(address => PartnerVote)) private partnerVotes;
    mapping(address => bool) public isPartner;
    mapping(address => bool) public isAnalyst;
    uint256 public dealCount;
    euint64 private _totalDeployedCapital;
    euint64 private _totalPortfolioValue;

    event DealSubmitted(uint256 indexed id, string company);
    event PartnerVoted(uint256 indexed dealId, address partner);
    event DealAdvanced(uint256 indexed dealId, DealStage stage);
    event DealClosed(uint256 indexed dealId, euint64 amount);

    modifier onlyPartner() {
        require(isPartner[msg.sender] || msg.sender == owner(), "Not partner");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDeployedCapital = FHE.asEuint64(0);
        _totalPortfolioValue = FHE.asEuint64(0);
        FHE.allowThis(_totalDeployedCapital);
        FHE.allowThis(_totalPortfolioValue);
        isPartner[msg.sender] = true;
    }

    function addPartner(address p) external onlyOwner { isPartner[p] = true; }
    function addAnalyst(address a) external onlyOwner { isAnalyst[a] = true; }

    function submitDeal(
        string calldata company, string calldata sector,
        externalEuint64 encAsk, bytes calldata aProof,
        externalEuint64 encValuation, bytes calldata vProof,
        externalEuint64 encARR, bytes calldata arrProof,
        externalEuint64 encBurn, bytes calldata bProof
    ) external returns (uint256 id) {
        require(isAnalyst[msg.sender] || isPartner[msg.sender], "Unauthorized");
        euint64 ask = FHE.fromExternal(encAsk, aProof);
        euint64 valuation = FHE.fromExternal(encValuation, vProof);
        euint64 arr = FHE.fromExternal(encARR, arrProof);
        euint64 burn = FHE.fromExternal(encBurn, bProof);
        id = dealCount++;
        deals[id] = Deal({
            companyName: company, sector: sector, requestedAmount: ask, preMoneyValuation: valuation,
            revenueARR: arr, burnRateMonthly: burn, partnerVoteScore: FHE.asEuint64(0),
            partnerVoteCount: 0, stage: DealStage.Screening, dealLead: msg.sender,
            submittedAt: block.timestamp
        });
        FHE.allowThis(deals[id].requestedAmount);
        FHE.allowThis(deals[id].preMoneyValuation);
        FHE.allowThis(deals[id].revenueARR);
        FHE.allowThis(deals[id].burnRateMonthly);
        FHE.allowThis(deals[id].partnerVoteScore);
        emit DealSubmitted(id, company);
    }

    function vote(uint256 dealId, externalEuint8 encScore, bytes calldata sProof,
                  externalEuint64 encCheckSize, bytes calldata cProof) external onlyPartner {
        require(!partnerVotes[dealId][msg.sender].voted, "Already voted");
        euint8 score = FHE.fromExternal(encScore, sProof);
        euint64 checkSize = FHE.fromExternal(encCheckSize, cProof);
        partnerVotes[dealId][msg.sender] = PartnerVote({ convictionScore: score, proposedTerms: checkSize, voted: true });
        deals[dealId].partnerVoteScore = FHE.add(deals[dealId].partnerVoteScore, FHE.asEuint64(uint64(0)));
        deals[dealId].partnerVoteCount++;
        FHE.allowThis(partnerVotes[dealId][msg.sender].convictionScore);
        FHE.allowThis(partnerVotes[dealId][msg.sender].proposedTerms);
        FHE.allowThis(deals[dealId].partnerVoteScore);
        emit PartnerVoted(dealId, msg.sender);
    }

    function advanceDeal(uint256 dealId, DealStage newStage) external onlyPartner {
        require(uint8(newStage) > uint8(deals[dealId].stage), "Invalid advance");
        deals[dealId].stage = newStage;
        emit DealAdvanced(dealId, newStage);
    }

    function closeDeal(uint256 dealId, externalEuint64 encFinalAmount, bytes calldata proof) external onlyPartner {
        euint64 finalAmt = FHE.fromExternal(encFinalAmount, proof);
        deals[dealId].stage = DealStage.Closed;
        _totalDeployedCapital = FHE.add(_totalDeployedCapital, finalAmt);
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, deals[dealId].preMoneyValuation);
        FHE.allowThis(_totalDeployedCapital);
        FHE.allowThis(_totalPortfolioValue);
        emit DealClosed(dealId, finalAmt);
    }

    function allowDealFinancials(uint256 dealId, address viewer) external onlyPartner {
        FHE.allow(deals[dealId].requestedAmount, viewer);
        FHE.allow(deals[dealId].preMoneyValuation, viewer);
        FHE.allow(deals[dealId].revenueARR, viewer);
        FHE.allow(deals[dealId].burnRateMonthly, viewer);
    }
}
