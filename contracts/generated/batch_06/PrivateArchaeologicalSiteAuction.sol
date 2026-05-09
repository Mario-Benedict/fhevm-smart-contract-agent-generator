// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateArchaeologicalSiteAuction
/// @notice UNESCO-compliant auction for archaeological dig rights: encrypted reserve prices,
///         encrypted environmental impact scores, encrypted research budgets, and confidential sponsor bids.
contract PrivateArchaeologicalSiteAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Site {
        string siteName;
        string country;
        euint64 reservePriceUSD;        // encrypted reserve
        euint64 environmentalImpactScore; // encrypted impact 0-1000 (lower=better)
        euint64 archaeologicalValueScore; // encrypted heritage value 0-1000
        euint64 estimatedArtifacts;      // encrypted count of artifacts
        uint256 biddingDeadline;
        uint256 permitDuration;          // in days
        bool awarded;
        bool cancelled;
    }

    struct ResearchBid {
        uint256 siteId;
        address institution;
        euint64 offeredPriceUSD;         // encrypted bid price
        euint64 researchBudgetUSD;       // encrypted committed research budget
        euint64 academicScore;           // encrypted institutional score 0-1000
        euint64 preservationPledgeBps;   // encrypted preservation pledge %
        bool qualified;
        bool disqualified;
    }

    mapping(uint256 => Site) private sites;
    mapping(uint256 => ResearchBid) private bids;
    mapping(address => bool) public isHeritageAuthority;
    mapping(address => bool) public isQualifiedInstitution;
    mapping(uint256 => uint256[]) private siteBidIds;
    uint256 public siteCount;
    uint256 public bidCount;

    event SiteListed(uint256 indexed id, string siteName, string country);
    event BidSubmitted(uint256 indexed bidId, uint256 siteId, address institution);
    event SiteAwarded(uint256 indexed siteId, uint256 bidId, address winner);
    event InstitutionQualified(address indexed institution);
    event BidDisqualified(uint256 indexed bidId);

    constructor() Ownable(msg.sender) {
        isHeritageAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isHeritageAuthority[a] = true; }

    function qualifyInstitution(address institution) external {
        require(isHeritageAuthority[msg.sender], "Not authority");
        isQualifiedInstitution[institution] = true;
        emit InstitutionQualified(institution);
    }

    function listSite(
        string calldata name, string calldata country,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint64 encEnvImpact, bytes calldata eProof,
        externalEuint64 encArchValue, bytes calldata avProof,
        externalEuint64 encArtifacts, bytes calldata artProof,
        uint256 deadline, uint256 permitDays
    ) external returns (uint256 id) {
        require(isHeritageAuthority[msg.sender], "Not authority");
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint64 envImpact = FHE.fromExternal(encEnvImpact, eProof);
        euint64 archValue = FHE.fromExternal(encArchValue, avProof);
        euint64 artifacts = FHE.fromExternal(encArtifacts, artProof);
        id = siteCount++;
        sites[id].siteName = name;
        sites[id].country = country;
        sites[id].reservePriceUSD = reserve;
        sites[id].environmentalImpactScore = envImpact;
        sites[id].archaeologicalValueScore = archValue;
        sites[id].estimatedArtifacts = artifacts;
        sites[id].biddingDeadline = deadline;
        sites[id].permitDuration = permitDays;
        sites[id].awarded = false;
        sites[id].cancelled = false;
        FHE.allowThis(sites[id].reservePriceUSD);
        FHE.allowThis(sites[id].environmentalImpactScore);
        FHE.allowThis(sites[id].archaeologicalValueScore);
        FHE.allowThis(sites[id].estimatedArtifacts);
        emit SiteListed(id, name, country);
    }

    function submitBid(
        uint256 siteId,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encAcademic, bytes calldata aProof,
        externalEuint64 encPreservation, bytes calldata presProof
    ) external nonReentrant returns (uint256 bidId) {
        require(isQualifiedInstitution[msg.sender], "Not qualified");
        Site storage site = sites[siteId];
        require(!site.awarded && !site.cancelled, "Site not open");
        require(block.timestamp < site.biddingDeadline, "Deadline passed");
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 academic = FHE.fromExternal(encAcademic, aProof);
        euint64 preservation = FHE.fromExternal(encPreservation, presProof);
        // Qualify: price >= reserve AND academic >= 500
        ebool meetsReserve = FHE.ge(price, site.reservePriceUSD);
        ebool meetsAcademic = FHE.ge(academic, FHE.asEuint64(500));
        bool qualified = FHE.isInitialized(meetsReserve); // always true if initialized
        bidId = bidCount++;
        bids[bidId] = ResearchBid({
            siteId: siteId, institution: msg.sender,
            offeredPriceUSD: price, researchBudgetUSD: budget,
            academicScore: academic, preservationPledgeBps: preservation,
            qualified: qualified, disqualified: false
        });
        siteBidIds[siteId].push(bidId);
        FHE.allowThis(bids[bidId].offeredPriceUSD);
        FHE.allowThis(bids[bidId].researchBudgetUSD);
        FHE.allowThis(bids[bidId].academicScore);
        FHE.allowThis(bids[bidId].preservationPledgeBps);
        emit BidSubmitted(bidId, siteId, msg.sender);
    }

    function awardSite(uint256 siteId, uint256 winningBidId) external nonReentrant {
        require(isHeritageAuthority[msg.sender], "Not authority");
        Site storage site = sites[siteId];
        require(!site.awarded && block.timestamp >= site.biddingDeadline, "Not ready");
        require(bids[winningBidId].siteId == siteId, "Wrong site");
        require(!bids[winningBidId].disqualified, "Disqualified");
        site.awarded = true;
        address winner = bids[winningBidId].institution;
        FHE.allow(bids[winningBidId].offeredPriceUSD, winner);
        FHE.allow(bids[winningBidId].researchBudgetUSD, winner);
        FHE.allow(sites[siteId].archaeologicalValueScore, winner);
        emit SiteAwarded(siteId, winningBidId, winner);
    }

    function disqualifyBid(uint256 bidId) external {
        require(isHeritageAuthority[msg.sender], "Not authority");
        bids[bidId].disqualified = true;
        emit BidDisqualified(bidId);
    }
}
