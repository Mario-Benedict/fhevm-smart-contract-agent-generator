// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDecentralizedScienceFundingDAO
/// @notice Encrypted DeSci funding: hidden research grant amounts, private peer
///         review scores, confidential researcher identity protection,
///         and encrypted protocol-controlled intellectual property licensing.
contract EncryptedDecentralizedScienceFundingDAO is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ResearchDomain { Biology, Chemistry, Physics, ComputerScience, Medicine, Economics, Materials }
    enum ProposalPhase { Submitted, InReview, Approved, Funded, Completed, Rejected }

    struct ResearchProposal {
        address principalInvestigator;
        ResearchDomain domain;
        string proposalRef;
        string abstractIPFSHash;
        euint64 requestedGrantUSD;     // encrypted grant request
        euint64 approvedGrantUSD;      // encrypted approved amount
        euint64 disbursedGrantUSD;     // encrypted disbursed
        euint64 ipLicensingRevenue;    // encrypted IP revenue
        euint16 peerReviewScore;       // encrypted peer review
        euint16 impactScore;           // encrypted impact score
        euint8  confidentialityLevel;  // encrypted confidentiality
        ProposalPhase phase;
        uint256 submittedAt;
    }

    struct Reviewer {
        address reviewerWallet;
        ResearchDomain expertise;
        euint16 reviewScore;           // encrypted given score
        euint8  conflictOfInterest;    // encrypted COI flag
        bool hasReviewed;
    }

    mapping(uint256 => ResearchProposal) private proposals;
    mapping(uint256 => mapping(address => Reviewer)) private reviewers;
    mapping(address => bool) public isPeerReviewer;
    mapping(address => bool) public isResearchCommittee;

    uint256 public proposalCount;
    euint64 private _totalGrantsAllocatedUSD;
    euint64 private _totalGrantsDisbursedUSD;
    euint64 private _totalIPRevenueUSD;
    euint64 private _daoTreasuryUSD;

    event ProposalSubmitted(uint256 indexed id, ResearchDomain domain);
    event ProposalReviewed(uint256 indexed id, address reviewer);
    event GrantApproved(uint256 indexed id, uint256 approvedAt);
    event GrantDisbursed(uint256 indexed id, uint256 disbursedAt);

    modifier onlyResearchCommittee() {
        require(isResearchCommittee[msg.sender] || msg.sender == owner(), "Not research committee");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalGrantsAllocatedUSD = FHE.asEuint64(0); _totalGrantsDisbursedUSD = FHE.asEuint64(0);
        _totalIPRevenueUSD = FHE.asEuint64(0); _daoTreasuryUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalGrantsAllocatedUSD); FHE.allowThis(_totalGrantsDisbursedUSD);
        FHE.allowThis(_totalIPRevenueUSD); FHE.allowThis(_daoTreasuryUSD);
        isResearchCommittee[msg.sender] = true;
    }

    function addPeerReviewer(address r) external onlyOwner { isPeerReviewer[r] = true; }
    function addResearchCommittee(address c) external onlyOwner { isResearchCommittee[c] = true; }

    function fundTreasury(externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        _daoTreasuryUSD = FHE.add(_daoTreasuryUSD, amt);
        FHE.allowThis(_daoTreasuryUSD);
    }

    function submitProposal(
        ResearchDomain domain, string calldata proposalRef, string calldata abstractHash,
        externalEuint64 encGrantRequest, bytes calldata grProof,
        externalEuint8 encConfLevel, bytes calldata clProof
    ) external returns (uint256 id) {
        euint64 grantRequest = FHE.fromExternal(encGrantRequest, grProof);
        euint8  confLevel    = FHE.fromExternal(encConfLevel, clProof);
        id = proposalCount++;
        ResearchProposal storage _s0 = proposals[id];
        _s0.principalInvestigator = msg.sender;
        _s0.domain = domain;
        _s0.proposalRef = proposalRef;
        _s0.abstractIPFSHash = abstractHash;
        _s0.requestedGrantUSD = grantRequest;
        _s0.approvedGrantUSD = FHE.asEuint64(0);
        _s0.disbursedGrantUSD = FHE.asEuint64(0);
        _s0.ipLicensingRevenue = FHE.asEuint64(0);
        _s0.peerReviewScore = FHE.asEuint16(0);
        _s0.impactScore = FHE.asEuint16(0);
        _s0.confidentialityLevel = confLevel;
        _s0.phase = ProposalPhase.Submitted;
        _s0.submittedAt = block.timestamp;
        FHE.allowThis(proposals[id].requestedGrantUSD); FHE.allow(proposals[id].requestedGrantUSD, msg.sender);
        FHE.allowThis(proposals[id].approvedGrantUSD); FHE.allow(proposals[id].approvedGrantUSD, msg.sender);
        FHE.allowThis(proposals[id].disbursedGrantUSD); FHE.allow(proposals[id].disbursedGrantUSD, msg.sender);
        FHE.allowThis(proposals[id].ipLicensingRevenue); FHE.allow(proposals[id].ipLicensingRevenue, msg.sender);
        FHE.allowThis(proposals[id].peerReviewScore); FHE.allowThis(proposals[id].impactScore);
        FHE.allowThis(proposals[id].confidentialityLevel);
        emit ProposalSubmitted(id, domain);
    }

    function submitReview(uint256 proposalId, externalEuint16 encScore, bytes calldata sProof, externalEuint8 encCOI, bytes calldata coiProof) external {
        require(isPeerReviewer[msg.sender] && !reviewers[proposalId][msg.sender].hasReviewed, "Cannot review");
        euint16 score = FHE.fromExternal(encScore, sProof);
        euint8  coi   = FHE.fromExternal(encCOI, coiProof);
        reviewers[proposalId][msg.sender] = Reviewer({ reviewerWallet: msg.sender, expertise: proposals[proposalId].domain, reviewScore: score, conflictOfInterest: coi, hasReviewed: true });
        proposals[proposalId].peerReviewScore = FHE.add(proposals[proposalId].peerReviewScore, score);
        FHE.allowThis(reviewers[proposalId][msg.sender].reviewScore);
        FHE.allowThis(reviewers[proposalId][msg.sender].conflictOfInterest);
        FHE.allowThis(proposals[proposalId].peerReviewScore);
        emit ProposalReviewed(proposalId, msg.sender);
    }

    function approveGrant(uint256 proposalId, externalEuint64 encApprovedAmt, bytes calldata proof) external onlyResearchCommittee {
        ResearchProposal storage p = proposals[proposalId];
        euint64 approvedAmt = FHE.fromExternal(encApprovedAmt, proof);
        ebool treasurySufficient = FHE.ge(_daoTreasuryUSD, approvedAmt);
        euint64 effApproved = FHE.select(treasurySufficient, approvedAmt, _daoTreasuryUSD);
        p.approvedGrantUSD = effApproved;
        p.phase = ProposalPhase.Approved;
        _totalGrantsAllocatedUSD = FHE.add(_totalGrantsAllocatedUSD, effApproved);
        FHE.allowThis(p.approvedGrantUSD); FHE.allow(p.approvedGrantUSD, p.principalInvestigator);
        FHE.allowThis(_totalGrantsAllocatedUSD);
        emit GrantApproved(proposalId, block.timestamp);
    }

    function disburseGrant(uint256 proposalId) external onlyResearchCommittee nonReentrant {
        ResearchProposal storage p = proposals[proposalId];
        require(p.phase == ProposalPhase.Approved, "Not approved");
        ebool _safeSub210 = FHE.ge(_daoTreasuryUSD, p.approvedGrantUSD);
        _daoTreasuryUSD = FHE.select(_safeSub210, FHE.sub(_daoTreasuryUSD, p.approvedGrantUSD), FHE.asEuint64(0));
        p.disbursedGrantUSD = p.approvedGrantUSD;
        _totalGrantsDisbursedUSD = FHE.add(_totalGrantsDisbursedUSD, p.approvedGrantUSD);
        p.phase = ProposalPhase.Funded;
        FHE.allow(p.disbursedGrantUSD, p.principalInvestigator);
        FHE.allowThis(p.disbursedGrantUSD); FHE.allowThis(_daoTreasuryUSD); FHE.allowThis(_totalGrantsDisbursedUSD);
        emit GrantDisbursed(proposalId, block.timestamp);
    }

    function allowDAOStats(address viewer) external onlyOwner {
        FHE.allow(_totalGrantsAllocatedUSD, viewer); FHE.allow(_totalGrantsDisbursedUSD, viewer); FHE.allow(_daoTreasuryUSD, viewer);
    }
}
