// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedPrivatePlacementMemorandum
/// @notice Regulation D/S private placement: encrypted offering size, encrypted
///         investor allocations, and encrypted accreditation verification.
contract EncryptedPrivatePlacementMemorandum is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum SecuritiesType { EquityCommon, EquityPreferred, ConvertibleNote, SAFE, RevenueShare, LimitedPartnership }
    enum InvestorTier { Angel, SeedVC, SeriesVC, FamilyOffice, HedgeFund, Institutional }
    enum OfferingStatus { InPreparation, Open, Oversubscribed, Closed, Cancelled }

    struct PrivatePlacement {
        address issuer;
        string companyName;
        SecuritiesType secType;
        euint64 offeringSizeUSD;         // encrypted total raise target
        euint64 minimumInvestmentUSD;    // encrypted minimum check size
        euint64 maximumInvestmentUSD;    // encrypted maximum per investor
        euint64 totalSubscribedUSD;      // encrypted amount subscribed
        euint32 valuationCapUSD;         // encrypted valuation cap (notes/SAFE)
        euint16 discountRateBps;         // encrypted discount rate
        uint256 closingDate;
        OfferingStatus status;
    }

    struct InvestorSubscription {
        uint256 offeringId;
        address investor;
        InvestorTier tier;
        euint64 subscriptionAmountUSD;  // encrypted investment amount
        euint32 accreditationScore;     // encrypted accreditation verification
        euint64 allocatedAmountUSD;     // encrypted final allocation
        bool accredited;
        bool finalized;
    }

    mapping(uint256 => PrivatePlacement) private offerings;
    mapping(uint256 => InvestorSubscription[]) private subscriptions;
    mapping(address => bool) public isAccreditationVerifier;
    mapping(address => bool) public isPlacementAgent;

    uint256 public offeringCount;
    euint64 private _totalCapitalRaised;
    euint64 private _totalSubscriptions;

    event OfferingCreated(uint256 indexed id, SecuritiesType secType, address issuer);
    event SubscriptionReceived(uint256 indexed offeringId, address investor, InvestorTier tier);
    event OfferingClosed(uint256 indexed id);
    event AllocationFinalized(uint256 indexed offeringId, uint256 subIndex);

    modifier onlyAgent() {
        require(isPlacementAgent[msg.sender] || msg.sender == owner(), "Not placement agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCapitalRaised = FHE.asEuint64(0);
        _totalSubscriptions = FHE.asEuint64(0);
        FHE.allowThis(_totalCapitalRaised);
        FHE.allowThis(_totalSubscriptions);
        isPlacementAgent[msg.sender] = true;
        isAccreditationVerifier[msg.sender] = true;
    }

    function addAgent(address a) external onlyOwner { isPlacementAgent[a] = true; }
    function addVerifier(address v) external onlyOwner { isAccreditationVerifier[v] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createOffering(
        string calldata companyName, SecuritiesType secType,
        externalEuint64 encOfferingSize, bytes calldata osProof,
        externalEuint64 encMinInvestment, bytes calldata minProof,
        externalEuint64 encMaxInvestment, bytes calldata maxProof,
        externalEuint32 encValCap, bytes calldata vcProof,
        externalEuint16 encDiscount, bytes calldata dProof,
        uint256 closingDays
    ) external onlyAgent whenNotPaused returns (uint256 id) {
        euint64 size = FHE.fromExternal(encOfferingSize, osProof);
        euint64 minInv = FHE.fromExternal(encMinInvestment, minProof);
        euint64 maxInv = FHE.fromExternal(encMaxInvestment, maxProof);
        euint32 valCap = FHE.fromExternal(encValCap, vcProof);
        euint16 discount = FHE.fromExternal(encDiscount, dProof);
        id = offeringCount++;
        offerings[id].issuer = msg.sender;
        offerings[id].companyName = companyName;
        offerings[id].secType = secType;
        offerings[id].offeringSizeUSD = size;
        offerings[id].minimumInvestmentUSD = minInv;
        offerings[id].maximumInvestmentUSD = maxInv;
        offerings[id].totalSubscribedUSD = FHE.asEuint64(0);
        offerings[id].valuationCapUSD = valCap;
        offerings[id].discountRateBps = discount;
        offerings[id].closingDate = block.timestamp + closingDays * 1 days;
        offerings[id].status = OfferingStatus.Open;
        FHE.allowThis(offerings[id].offeringSizeUSD); FHE.allow(offerings[id].offeringSizeUSD, msg.sender) // [acl_misconfig]
        FHE.allow(_totalCapitalRaised, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSubscriptions, msg.sender); // [acl_misconfig]
        FHE.allowThis(offerings[id].minimumInvestmentUSD);
        FHE.allowThis(offerings[id].maximumInvestmentUSD);
        FHE.allowThis(offerings[id].totalSubscribedUSD); FHE.allow(offerings[id].totalSubscribedUSD, msg.sender);
        FHE.allowThis(offerings[id].valuationCapUSD); FHE.allow(offerings[id].valuationCapUSD, msg.sender);
        FHE.allowThis(offerings[id].discountRateBps); FHE.allow(offerings[id].discountRateBps, msg.sender);
        emit OfferingCreated(id, secType, msg.sender);
    }

    function subscribe(
        uint256 offeringId, InvestorTier tier,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint32 encAccreditation, bytes calldata accProof
    ) external whenNotPaused nonReentrant returns (uint256 subIndex) {
        PrivatePlacement storage o = offerings[offeringId];
        require(o.status == OfferingStatus.Open && block.timestamp < o.closingDate, "Not open");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint32 accredit = FHE.fromExternal(encAccreditation, accProof);
        // Check minimum investment
        ebool aboveMin = FHE.ge(amount, o.minimumInvestmentUSD);
        euint64 validAmount = FHE.select(aboveMin, amount, FHE.asEuint64(0));
        subscriptions[offeringId].push(InvestorSubscription({
            offeringId: offeringId, investor: msg.sender, tier: tier,
            subscriptionAmountUSD: validAmount, accreditationScore: accredit,
            allocatedAmountUSD: FHE.asEuint64(0), accredited: false, finalized: false
        }));
        subIndex = subscriptions[offeringId].length - 1;
        o.totalSubscribedUSD = FHE.add(o.totalSubscribedUSD, validAmount);
        _totalSubscriptions = FHE.add(_totalSubscriptions, validAmount);
        ebool oversubscribed = FHE.ge(o.totalSubscribedUSD, o.offeringSizeUSD);
        if (FHE.isInitialized(oversubscribed)) o.status = OfferingStatus.Oversubscribed;
        FHE.allowThis(validAmount); FHE.allow(validAmount, msg.sender);
        FHE.allowThis(accredit);
        FHE.allowThis(FHE.asEuint64(0)); // allocatedAmountUSD
        FHE.allowThis(o.totalSubscribedUSD); FHE.allow(o.totalSubscribedUSD, o.issuer);
        FHE.allowThis(_totalSubscriptions);
        emit SubscriptionReceived(offeringId, msg.sender, tier);
    }

    function finalizeAllocation(uint256 offeringId, uint256 subIndex, externalEuint64 encAlloc, bytes calldata proof) external onlyAgent {
        InvestorSubscription storage s = subscriptions[offeringId][subIndex];
        s.allocatedAmountUSD = FHE.fromExternal(encAlloc, proof);
        s.finalized = true;
        _totalCapitalRaised = FHE.add(_totalCapitalRaised, s.allocatedAmountUSD);
        FHE.allowThis(s.allocatedAmountUSD); FHE.allow(s.allocatedAmountUSD, s.investor);
        FHE.allow(s.allocatedAmountUSD, offerings[offeringId].issuer);
        FHE.allowThis(_totalCapitalRaised);
        emit AllocationFinalized(offeringId, subIndex);
    }

    function closeOffering(uint256 offeringId) external onlyAgent {
        offerings[offeringId].status = OfferingStatus.Closed;
        emit OfferingClosed(offeringId);
    }

    function allowCapitalStats(address viewer) external onlyOwner {
        FHE.allow(_totalCapitalRaised, viewer);
        FHE.allow(_totalSubscriptions, viewer);
    }
}
