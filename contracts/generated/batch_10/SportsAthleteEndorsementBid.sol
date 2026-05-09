// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SportsAthleteEndorsementBid
/// @notice Brands submit encrypted endorsement offers for athletes.
///         Athlete's agent reviews bids without revealing competing amounts.
///         Complex multi-year deal structures with encrypted milestone bonuses.
contract SportsAthleteEndorsementBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct EndorsementDeal {
        address athlete;
        string athleteName;
        euint64 annualBaseSalary;   // encrypted per year
        euint64 signingBonus;       // encrypted signing bonus
        euint64 performanceBonus;   // encrypted bonus per milestone
        euint8 contractYears;
        uint8 milestonesAchieved;
        uint256 signedAt;
        bool active;
        address brand;
    }

    struct BrandBid {
        euint64 annualOffer;        // encrypted annual offer
        euint64 signingBonus;       // encrypted signing offer
        euint64 performanceTrigger; // encrypted milestone bonus
        uint8 yearsOffered;
        bool submitted;
        bool accepted;
    }

    mapping(uint256 => EndorsementDeal) private deals;
    mapping(uint256 => mapping(address => BrandBid)) private brandBids;
    mapping(address => bool) public isBrand;
    mapping(address => bool) public isAgent;
    uint256 public dealCount;
    euint64 private _totalEndorsementMarket; // encrypted total market size tracked

    event DealOpenedForBids(uint256 indexed id, string athlete);
    event BidSubmitted(uint256 indexed dealId, address brand);
    event DealSigned(uint256 indexed dealId, address brand);
    event MilestoneAchieved(uint256 indexed dealId, uint8 count);

    modifier onlyAgent() {
        require(isAgent[msg.sender] || msg.sender == owner(), "Not agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEndorsementMarket = FHE.asEuint64(0);
        FHE.allowThis(_totalEndorsementMarket);
        isAgent[msg.sender] = true;
    }

    function addBrand(address b) external onlyOwner { isBrand[b] = true; }
    function addAgent(address a) external onlyOwner { isAgent[a] = true; }

    function openDealForBids(address athlete, string calldata athleteName) external onlyAgent returns (uint256 id) {
        id = dealCount++;
        deals[id].athlete = athlete;
        deals[id].athleteName = athleteName;
        deals[id].annualBaseSalary = FHE.asEuint64(0);
        deals[id].signingBonus = FHE.asEuint64(0);
        deals[id].performanceBonus = FHE.asEuint64(0);
        deals[id].contractYears = FHE.asEuint8(0);
        deals[id].milestonesAchieved = 0;
        deals[id].signedAt = 0;
        deals[id].active = false;
        deals[id].brand = address(0);
        FHE.allowThis(deals[id].annualBaseSalary);
        FHE.allowThis(deals[id].signingBonus);
        FHE.allowThis(deals[id].performanceBonus);
        emit DealOpenedForBids(id, athleteName);
    }

    function submitBid(
        uint256 dealId,
        externalEuint64 encAnnual, bytes calldata aProof,
        externalEuint64 encSigning, bytes calldata sProof,
        externalEuint64 encPerf, bytes calldata pProof,
        uint8 yearsOffered_
    ) external nonReentrant {
        require(isBrand[msg.sender], "Not brand");
        require(!deals[dealId].active, "Already signed");
        euint64 annual = FHE.fromExternal(encAnnual, aProof);
        euint64 signing = FHE.fromExternal(encSigning, sProof);
        euint64 perf = FHE.fromExternal(encPerf, pProof);
        brandBids[dealId][msg.sender] = BrandBid({
            annualOffer: annual, signingBonus: signing, performanceTrigger: perf,
            yearsOffered: yearsOffered_, submitted: true, accepted: false
        });
        FHE.allowThis(brandBids[dealId][msg.sender].annualOffer);
        FHE.allow(brandBids[dealId][msg.sender].annualOffer, deals[dealId].athlete);
        FHE.allowThis(brandBids[dealId][msg.sender].signingBonus);
        FHE.allowThis(brandBids[dealId][msg.sender].performanceTrigger);
        emit BidSubmitted(dealId, msg.sender);
    }

    function acceptBid(uint256 dealId, address brand) external onlyAgent {
        EndorsementDeal storage d = deals[dealId];
        BrandBid storage bid = brandBids[dealId][brand];
        require(bid.submitted && !d.active, "Invalid");
        bid.accepted = true;
        d.annualBaseSalary = bid.annualOffer;
        d.signingBonus = bid.signingBonus;
        d.performanceBonus = bid.performanceTrigger;
        d.contractYears = FHE.asEuint8(bid.yearsOffered);
        d.brand = brand;
        d.signedAt = block.timestamp;
        d.active = true;
        _totalEndorsementMarket = FHE.add(_totalEndorsementMarket, bid.annualOffer);
        FHE.allowThis(d.annualBaseSalary);
        FHE.allow(d.annualBaseSalary, d.athlete);
        FHE.allow(d.annualBaseSalary, brand);
        FHE.allowThis(d.signingBonus);
        FHE.allow(d.signingBonus, d.athlete);
        FHE.allowThis(d.performanceBonus);
        FHE.allow(d.performanceBonus, d.athlete);
        FHE.allowThis(_totalEndorsementMarket);
        emit DealSigned(dealId, brand);
    }

    function recordMilestone(uint256 dealId) external {
        require(deals[dealId].brand == msg.sender || isAgent[msg.sender], "Unauthorized");
        deals[dealId].milestonesAchieved++;
        FHE.allow(deals[dealId].performanceBonus, deals[dealId].athlete);
        emit MilestoneAchieved(dealId, deals[dealId].milestonesAchieved);
    }

    function allowDealDetails(uint256 dealId, address viewer) external onlyAgent {
        FHE.allow(deals[dealId].annualBaseSalary, viewer);
        FHE.allow(deals[dealId].signingBonus, viewer);
        FHE.allow(deals[dealId].performanceBonus, viewer);
    }
}
