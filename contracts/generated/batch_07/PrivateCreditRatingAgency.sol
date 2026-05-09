// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCreditRatingAgency
/// @notice On-chain credit agency: issuers submit financials with encrypted metrics,
///         analysts assign encrypted ratings, rating revealed to approved counterparties only.
contract PrivateCreditRatingAgency is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RatingCategory { CorporateBond, SovereignDebt, StructuredProduct, MunicipalBond }
    enum RatingOutlook { Stable, Positive, Negative, Developing }

    struct CreditRating {
        address issuer;
        RatingCategory category;
        string issuerName;
        euint8 ratingScore;              // encrypted 1-100 (AAA=100, D=1)
        euint64 debtOutstanding;         // encrypted total debt
        euint8 defaultProbabilityBps;    // encrypted probability of default
        euint64 recoveryRateBps;         // encrypted recovery rate if default
        RatingOutlook outlook;
        uint256 issuedAt;
        uint256 validUntil;
        bool published;
        address leadAnalyst;
    }

    struct Subscriber {
        euint64 subscriptionFee;         // encrypted fee paid
        uint256 subscriptionEnd;
        bool active;
    }

    mapping(uint256 => CreditRating) private ratings;
    mapping(address => Subscriber) private subscribers;
    mapping(address => bool) public isAnalyst;
    mapping(address => bool) public isRatingCommittee;
    mapping(uint256 => mapping(address => bool)) private _ratingAccess;
    uint256 public ratingCount;
    euint64 private _totalSubscriptionRevenue;
    euint64 private _annualSubscriptionFee;

    event RatingIssued(uint256 indexed id, string issuerName, RatingCategory category);
    event RatingUpdated(uint256 indexed id);
    event SubscriberAdded(address indexed subscriber);
    event RatingAccessGranted(uint256 indexed ratingId, address subscriber);

    modifier onlyAnalyst() {
        require(isAnalyst[msg.sender] || msg.sender == owner(), "Not analyst");
        _;
    }

    constructor(externalEuint64 encSubFee, bytes memory proof) Ownable(msg.sender) {
        _annualSubscriptionFee = FHE.fromExternal(encSubFee, proof);
        _totalSubscriptionRevenue = FHE.asEuint64(0);
        FHE.allowThis(_annualSubscriptionFee);
        FHE.allowThis(_totalSubscriptionRevenue);
        isAnalyst[msg.sender] = true;
        isRatingCommittee[msg.sender] = true;
    }

    function addAnalyst(address a) external onlyOwner { isAnalyst[a] = true; }
    function addCommittee(address c) external onlyOwner { isRatingCommittee[c] = true; }

    function subscribe(externalEuint64 encFee, bytes calldata proof) external {
        euint64 fee = FHE.fromExternal(encFee, proof);
        ebool feeSufficient = FHE.ge(fee, _annualSubscriptionFee);
        euint64 accepted = FHE.select(feeSufficient, _annualSubscriptionFee, FHE.asEuint64(0));
        subscribers[msg.sender] = Subscriber({
            subscriptionFee: accepted, subscriptionEnd: block.timestamp + 365 days, active: true
        });
        _totalSubscriptionRevenue = FHE.add(_totalSubscriptionRevenue, accepted);
        FHE.allowThis(subscribers[msg.sender].subscriptionFee);
        FHE.allowThis(_totalSubscriptionRevenue);
        emit SubscriberAdded(msg.sender);
    }

    function issueRating(
        address issuer, RatingCategory category, string calldata issuerName,
        externalEuint8 encScore, bytes calldata sProof,
        externalEuint64 encDebt, bytes calldata dProof,
        externalEuint8 encDefaultProb, bytes calldata dpProof,
        externalEuint64 encRecovery, bytes calldata rProof,
        RatingOutlook outlook, uint256 validityDays
    ) external onlyAnalyst returns (uint256 id) {
        euint8 score = FHE.fromExternal(encScore, sProof);
        euint64 debt = FHE.fromExternal(encDebt, dProof);
        euint8 defProb = FHE.fromExternal(encDefaultProb, dpProof);
        euint64 recovery = FHE.fromExternal(encRecovery, rProof);
        id = ratingCount++;
        CreditRating storage _s0 = ratings[id];
        _s0.issuer = issuer;
        _s0.category = category;
        _s0.issuerName = issuerName;
        _s0.ratingScore = score;
        _s0.debtOutstanding = debt;
        _s0.defaultProbabilityBps = defProb;
        _s0.recoveryRateBps = recovery;
        _s0.outlook = outlook;
        _s0.issuedAt = block.timestamp;
        _s0.validUntil = block.timestamp + validityDays * 1 days;
        _s0.published = false;
        _s0.leadAnalyst = msg.sender;
        FHE.allowThis(ratings[id].ratingScore);
        FHE.allowThis(ratings[id].debtOutstanding);
        FHE.allowThis(ratings[id].defaultProbabilityBps);
        FHE.allowThis(ratings[id].recoveryRateBps);
        emit RatingIssued(id, issuerName, category);
    }

    function publishRating(uint256 ratingId) external {
        require(isRatingCommittee[msg.sender], "Not committee");
        ratings[ratingId].published = true;
    }

    function updateRating(uint256 ratingId, externalEuint8 encNewScore, bytes calldata proof, RatingOutlook newOutlook) external onlyAnalyst {
        euint8 newScore = FHE.fromExternal(encNewScore, proof);
        ratings[ratingId].ratingScore = newScore;
        ratings[ratingId].outlook = newOutlook;
        ratings[ratingId].issuedAt = block.timestamp;
        FHE.allowThis(ratings[ratingId].ratingScore);
        emit RatingUpdated(ratingId);
    }

    function grantRatingAccess(uint256 ratingId, address subscriber) external onlyAnalyst {
        require(ratings[ratingId].published, "Not published");
        require(subscribers[subscriber].active && block.timestamp < subscribers[subscriber].subscriptionEnd, "Not subscriber");
        _ratingAccess[ratingId][subscriber] = true;
        FHE.allow(ratings[ratingId].ratingScore, subscriber);
        FHE.allow(ratings[ratingId].defaultProbabilityBps, subscriber);
        FHE.allow(ratings[ratingId].recoveryRateBps, subscriber);
        emit RatingAccessGranted(ratingId, subscriber);
    }

    function allowRatingToIssuer(uint256 ratingId) external {
        require(ratings[ratingId].issuer == msg.sender, "Not issuer");
        FHE.allow(ratings[ratingId].ratingScore, msg.sender);
        FHE.allow(ratings[ratingId].debtOutstanding, msg.sender);
    }

    function allowAgencyStats(address viewer) external onlyOwner {
        FHE.allow(_totalSubscriptionRevenue, viewer);
    }
}
