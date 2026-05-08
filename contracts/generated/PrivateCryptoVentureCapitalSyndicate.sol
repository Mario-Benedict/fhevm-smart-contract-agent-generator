// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCryptoVentureCapitalSyndicate
/// @notice VC syndicate with encrypted deal terms, confidential cap table management,
///         private pro-rata rights, and encrypted portfolio company valuations.
contract PrivateCryptoVentureCapitalSyndicate is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum DealStage { PRE_SEED, SEED, SERIES_A, SERIES_B, SERIES_C, GROWTH, PRE_IPO }
    enum TokenType { EQUITY, TOKEN_WARRANT, SAFE, CONVERTIBLE_NOTE, TOKEN_ONLY }

    struct PortfolioDeal {
        string companyName;
        DealStage stage;
        TokenType tokenType;
        euint64 preMoneyValuationUSD;   // encrypted pre-money valuation
        euint64 postMoneyValuationUSD;  // encrypted post-money valuation
        euint64 roundSizeUSD;           // encrypted round size
        euint64 syndicateAllocationUSD; // encrypted syndicate check size
        euint64 pricePerShareUSD;       // encrypted price per share/token
        euint64 ownershipPctBps;        // encrypted syndicate ownership
        euint64 conversionDiscountBps;  // encrypted SAFE/note discount
        euint64 valuationCapUSD;        // encrypted valuation cap (for SAFEs)
        euint64 currentMarkUSD;         // encrypted current mark-to-market
        uint256 investmentDate;
        bool active;
        bool exited;
    }

    struct SyndicateMember {
        euint64 totalCommittedUSD;     // encrypted total committed capital
        euint64 totalDeployedUSD;      // encrypted deployed capital
        euint64 unrealizedGainsUSD;    // encrypted unrealized gains
        euint64 realizedGainsUSD;      // encrypted realized returns
        euint64 carriedInterestBps;    // encrypted carry percentage
        euint64 managementFeeBps;      // encrypted management fee
        uint256 memberSince;
        bool approved;
        bool leadInvestor;
    }

    struct ProRataRight {
        address member;
        uint256 dealId;
        euint64 proRataAllocationUSD;  // encrypted pro-rata entitlement
        euint64 exercisedUSD;          // encrypted amount exercised
        uint256 expiryDate;
        bool exercised;
    }

    mapping(uint256 => PortfolioDeal) private deals;
    mapping(address => SyndicateMember) private members;
    mapping(bytes32 => ProRataRight) private proRataRights; // keccak(member, dealId)
    mapping(address => bool) public isGP;  // General Partner

    uint256 public dealCount;
    euint64 private _totalAUM;
    euint64 private _totalCarryEarned;
    euint64 private _portfolioTotalCurrentMark;

    event DealSourced(uint256 indexed dealId, string company, DealStage stage);
    event MemberJoined(address indexed member);
    event AllocationMade(uint256 indexed dealId, address indexed member);
    event MarkUpdated(uint256 indexed dealId, uint256 timestamp);
    event ExitProcessed(uint256 indexed dealId);
    event ProRataExercised(bytes32 indexed proRataKey);

    constructor() Ownable(msg.sender) {
        _totalAUM = FHE.asEuint64(0);
        _totalCarryEarned = FHE.asEuint64(0);
        _portfolioTotalCurrentMark = FHE.asEuint64(0);
        FHE.allowThis(_totalAUM);
        FHE.allowThis(_totalCarryEarned);
        FHE.allowThis(_portfolioTotalCurrentMark);
        isGP[msg.sender] = true;
    }

    modifier onlyGP() { require(isGP[msg.sender], "Not GP"); _; }

    function sourceDeal(
        string calldata companyName,
        DealStage stage,
        TokenType tokenType,
        externalEuint64 encPreMoney, bytes calldata pmProof,
        externalEuint64 encRoundSize, bytes calldata rsProof,
        externalEuint64 encSyndicateAlloc, bytes calldata saProof,
        externalEuint64 encPricePerShare, bytes calldata ppsProof,
        externalEuint64 encValCap, bytes calldata vcProof
    ) external onlyGP returns (uint256 dealId) {
        dealId = dealCount++;
        PortfolioDeal storage pd = deals[dealId];
        pd.companyName = companyName;
        pd.stage = stage;
        pd.tokenType = tokenType;
        pd.preMoneyValuationUSD = FHE.fromExternal(encPreMoney, pmProof);
        pd.roundSizeUSD = FHE.fromExternal(encRoundSize, rsProof);
        pd.postMoneyValuationUSD = FHE.add(pd.preMoneyValuationUSD, pd.roundSizeUSD);
        pd.syndicateAllocationUSD = FHE.fromExternal(encSyndicateAlloc, saProof);
        pd.pricePerShareUSD = FHE.fromExternal(encPricePerShare, ppsProof);
        pd.valuationCapUSD = FHE.fromExternal(encValCap, vcProof);
        pd.ownershipPctBps = FHE.div(FHE.mul(pd.syndicateAllocationUSD, 10000), pd.postMoneyValuationUSD);
        pd.currentMarkUSD = pd.syndicateAllocationUSD;
        pd.conversionDiscountBps = FHE.asEuint64(2000); // 20% default discount
        pd.investmentDate = block.timestamp;
        pd.active = true;
        _totalAUM = FHE.add(_totalAUM, pd.syndicateAllocationUSD);
        FHE.allowThis(pd.preMoneyValuationUSD);
        FHE.allowThis(pd.postMoneyValuationUSD);
        FHE.allowThis(pd.roundSizeUSD);
        FHE.allowThis(pd.syndicateAllocationUSD);
        FHE.allowThis(pd.pricePerShareUSD);
        FHE.allowThis(pd.ownershipPctBps);
        FHE.allowThis(pd.currentMarkUSD);
        FHE.allowThis(pd.valuationCapUSD);
        FHE.allowThis(_totalAUM);
        emit DealSourced(dealId, companyName, stage);
    }

    function addMember(
        address member,
        externalEuint64 encCommitment, bytes calldata cProof,
        externalEuint64 encCarry, bytes calldata carryProof,
        bool isLead
    ) external onlyGP {
        require(!members[member].approved, "Already member");
        SyndicateMember storage sm = members[member];
        sm.totalCommittedUSD = FHE.fromExternal(encCommitment, cProof);
        sm.totalDeployedUSD = FHE.asEuint64(0);
        sm.unrealizedGainsUSD = FHE.asEuint64(0);
        sm.realizedGainsUSD = FHE.asEuint64(0);
        sm.carriedInterestBps = FHE.fromExternal(encCarry, carryProof);
        sm.managementFeeBps = FHE.asEuint64(200); // 2% default
        sm.memberSince = block.timestamp;
        sm.approved = true;
        sm.leadInvestor = isLead;
        FHE.allowThis(sm.totalCommittedUSD);
        FHE.allow(sm.totalCommittedUSD, member);
        FHE.allowThis(sm.totalDeployedUSD);
        FHE.allow(sm.totalDeployedUSD, member);
        FHE.allowThis(sm.unrealizedGainsUSD);
        FHE.allow(sm.unrealizedGainsUSD, member);
        FHE.allowThis(sm.realizedGainsUSD);
        FHE.allow(sm.realizedGainsUSD, member);
        FHE.allowThis(sm.carriedInterestBps);
        FHE.allow(sm.carriedInterestBps, member);
        emit MemberJoined(member);
    }

    function allocateDeal(
        address member,
        uint256 dealId,
        externalEuint64 encAllocation, bytes calldata aProof
    ) external onlyGP {
        SyndicateMember storage sm = members[member];
        require(sm.approved, "Not member");
        PortfolioDeal storage pd = deals[dealId];
        require(pd.active, "Deal not active");
        euint64 allocation = FHE.fromExternal(encAllocation, aProof);
        // Ensure within syndicate allocation
        ebool withinAlloc = FHE.le(allocation, pd.syndicateAllocationUSD);
        euint64 actualAlloc = FHE.select(withinAlloc, allocation, pd.syndicateAllocationUSD);
        sm.totalDeployedUSD = FHE.add(sm.totalDeployedUSD, actualAlloc);
        // Grant pro-rata right for future rounds
        bytes32 proRataKey = keccak256(abi.encodePacked(member, dealId));
        proRataRights[proRataKey] = ProRataRight({
            member: member, dealId: dealId,
            proRataAllocationUSD: FHE.div(FHE.mul(actualAlloc, pd.ownershipPctBps), 10000),
            exercisedUSD: FHE.asEuint64(0),
            expiryDate: block.timestamp + 365 days,
            exercised: false
        });
        FHE.allowThis(sm.totalDeployedUSD);
        FHE.allow(sm.totalDeployedUSD, member);
        FHE.allowThis(proRataRights[proRataKey].proRataAllocationUSD);
        FHE.allow(proRataRights[proRataKey].proRataAllocationUSD, member);
        emit AllocationMade(dealId, member);
    }

    function updateMark(
        uint256 dealId,
        externalEuint64 encNewMark, bytes calldata nmProof
    ) external onlyGP {
        PortfolioDeal storage pd = deals[dealId];
        euint64 oldMark = pd.currentMarkUSD;
        pd.currentMarkUSD = FHE.fromExternal(encNewMark, nmProof);
        _portfolioTotalCurrentMark = FHE.add(
            FHE.sub(_portfolioTotalCurrentMark, oldMark), pd.currentMarkUSD);
        FHE.allowThis(pd.currentMarkUSD);
        FHE.allowThis(_portfolioTotalCurrentMark);
        emit MarkUpdated(dealId, block.timestamp);
    }

    function processExit(
        uint256 dealId,
        externalEuint64 encExitProceeds, bytes calldata epProof,
        address member
    ) external onlyGP nonReentrant {
        PortfolioDeal storage pd = deals[dealId];
        SyndicateMember storage sm = members[member];
        require(pd.active && !pd.exited, "Invalid state");
        euint64 proceeds = FHE.fromExternal(encExitProceeds, epProof);
        euint64 gain = FHE.select(FHE.gt(proceeds, sm.totalDeployedUSD),
            FHE.sub(proceeds, sm.totalDeployedUSD), FHE.asEuint64(0));
        // Calculate carry
        euint64 carry = FHE.div(FHE.mul(gain, sm.carriedInterestBps), 10000);
        euint64 memberProceeds = FHE.sub(proceeds, carry);
        sm.realizedGainsUSD = FHE.add(sm.realizedGainsUSD, FHE.sub(gain, carry));
        _totalCarryEarned = FHE.add(_totalCarryEarned, carry);
        pd.exited = true;
        pd.active = false;
        FHE.allowThis(sm.realizedGainsUSD);
        FHE.allow(sm.realizedGainsUSD, member);
        FHE.allowThis(_totalCarryEarned);
        FHE.allowTransient(memberProceeds, member);
        emit ExitProcessed(dealId);
    }

    function addGP(address gp) external onlyOwner { isGP[gp] = true; }
    function allowFundStats(address lp) external onlyGP {
        FHE.allow(_totalAUM, lp);
        FHE.allow(_portfolioTotalCurrentMark, lp);
    }
}
