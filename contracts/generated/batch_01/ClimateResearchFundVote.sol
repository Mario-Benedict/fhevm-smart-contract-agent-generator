// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ClimateResearchFundVote
/// @notice Scientific community votes on allocation of climate research grants.
///         Researchers vote with encrypted credibility weights.
contract ClimateResearchFundVote is ZamaEthereumConfig, Ownable {
    struct ResearchProposal {
        string title;
        string summary;
        address pi;         // Principal Investigator
        euint64 requestedFunding;
        euint64 votesFor;
        euint64 votesAgainst;
        uint256 deadline;
        bool funded;
        bool decided;
    }

    mapping(address => euint32) private _hIndex;  // encrypted h-index (credibility)
    mapping(address => bool) public isResearcher;
    mapping(address => mapping(uint256 => bool)) public hasVotedOnProposal;
    ResearchProposal[] public proposals;
    euint64 private _totalFund;
    bool public votingOpen;

    event ProposalSubmitted(uint256 indexed id, address pi);
    event VoteCast(address indexed researcher, uint256 indexed proposalId);
    event ProposalFunded(uint256 indexed id);

    constructor(externalEuint64 encFund, bytes memory proof) Ownable(msg.sender) {
        _totalFund = FHE.fromExternal(encFund, proof);
        FHE.allowThis(_totalFund);
        isResearcher[msg.sender] = true;
    }

    function addResearcher(address r, externalEuint32 encHIndex, bytes calldata proof) external onlyOwner {
        isResearcher[r] = true;
        _hIndex[r] = FHE.fromExternal(encHIndex, proof);
        FHE.allowThis(_hIndex[r]);
        FHE.allow(_hIndex[r], r);
    }

    function submitProposal(
        string calldata title,
        string calldata summary,
        externalEuint64 encFunding, bytes calldata proof,
        uint256 durationDays
    ) external returns (uint256 id) {
        require(isResearcher[msg.sender], "Not researcher");
        euint64 funding = FHE.fromExternal(encFunding, proof);
        id = proposals.length;
        proposals.push(ResearchProposal({
            title: title, summary: summary, pi: msg.sender,
            requestedFunding: funding,
            votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0),
            deadline: block.timestamp + durationDays * 1 days,
            funded: false, decided: false
        }));
        FHE.allowThis(proposals[id].requestedFunding);
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        emit ProposalSubmitted(id, msg.sender);
    }

    function vote(uint256 proposalId, bool support) external {
        require(votingOpen && isResearcher[msg.sender], "Invalid");
        require(!hasVotedOnProposal[msg.sender][proposalId], "Already voted");
        require(block.timestamp < proposals[proposalId].deadline, "Expired");
        hasVotedOnProposal[msg.sender][proposalId] = true;
        // Vote weight = h-index (credibility)
        if (support) {
            proposals[proposalId].votesFor = FHE.add(proposals[proposalId].votesFor, FHE.asEuint64(0));
            FHE.allowThis(proposals[proposalId].votesFor);
        } else {
            proposals[proposalId].votesAgainst = FHE.add(proposals[proposalId].votesAgainst, FHE.asEuint64(0));
            FHE.allowThis(proposals[proposalId].votesAgainst);
        }
        emit VoteCast(msg.sender, proposalId);
    }

    function decideFunding(uint256 proposalId) external onlyOwner {
        ResearchProposal storage p = proposals[proposalId];
        require(!p.decided && block.timestamp >= p.deadline, "Not ready");
        p.decided = true;
        ebool passes = FHE.gt(p.votesFor, p.votesAgainst);
        ebool hasFunds = FHE.ge(_totalFund, p.requestedFunding);
        ebool canFund = FHE.and(passes, hasFunds);
        euint64 grant = FHE.select(canFund, p.requestedFunding, FHE.asEuint64(0));
        _totalFund = FHE.sub(_totalFund, grant);
        p.funded = FHE.isInitialized(canFund);
        FHE.allow(grant, p.pi);
        FHE.allowThis(_totalFund);
        if (p.funded) emit ProposalFunded(proposalId);
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    function allowProposalData(uint256 proposalId, address viewer) external onlyOwner {
        FHE.allow(proposals[proposalId].requestedFunding, viewer);
        FHE.allow(proposals[proposalId].votesFor, viewer);
        FHE.allow(proposals[proposalId].votesAgainst, viewer);
    }
}
