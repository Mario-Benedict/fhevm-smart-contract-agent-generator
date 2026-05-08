// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateGamingGuildTreasuryDAO
/// @notice Encrypted gaming guild DAO treasury: hidden token holdings, confidential
///         scholarship program profit shares, private guild revenue from tournaments,
///         and encrypted member contribution scores for governance weight.
contract PrivateGamingGuildTreasuryDAO is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum GuildRank { Recruit, Member, Veteran, Officer, Champion, Grandmaster }
    enum ProposalStatus { Pending, Active, Passed, Failed, Executed }

    struct GuildMember {
        address memberAddress;
        GuildRank rank;
        euint64 tokenContributionUSD;  // encrypted token contributions to treasury
        euint64 scholarshipEarningsUSD;// encrypted earnings from scholarship
        euint64 tournamentRevenueUSD;  // encrypted tournament prize share
        euint32 contributionScore;     // encrypted overall contribution score
        euint16 governanceWeightBps;   // encrypted governance voting weight
        uint256 joinedAt;
        bool active;
    }

    struct TreasuryProposal {
        address proposer;
        string description;
        euint64 requestedAmountUSD;    // encrypted requested treasury allocation
        euint64 votesFor;              // encrypted votes in favor
        euint64 votesAgainst;          // encrypted votes against
        uint32 voterCount;
        ProposalStatus status;
        uint256 createdAt;
        uint256 votingEnd;
    }

    mapping(uint256 => GuildMember) private members;
    mapping(address => uint256) private memberIndex;
    mapping(uint256 => TreasuryProposal) private proposals;
    mapping(address => bool) public isGuildAdmin;

    uint256 public memberCount;
    uint256 public proposalCount;
    euint64 private _totalTreasuryUSD;
    euint64 private _totalScholarshipPaidUSD;
    euint64 private _totalTournamentRevenueUSD;

    event MemberEnrolled(uint256 indexed id, GuildRank rank);
    event ProposalCreated(uint256 indexed id, address proposer);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyGuildAdmin() {
        require(isGuildAdmin[msg.sender] || msg.sender == owner(), "Not guild admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTreasuryUSD = FHE.asEuint64(0);
        _totalScholarshipPaidUSD = FHE.asEuint64(0);
        _totalTournamentRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalTreasuryUSD);
        FHE.allowThis(_totalScholarshipPaidUSD);
        FHE.allowThis(_totalTournamentRevenueUSD);
        isGuildAdmin[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addGuildAdmin(address a) external onlyOwner { isGuildAdmin[a] = true; }

    function enrollMember(
        address memberAddress, GuildRank rank,
        externalEuint64 encTokenContrib, bytes calldata tcProof,
        externalEuint32 encContribScore, bytes calldata csProof,
        externalEuint16 encGovWeight, bytes calldata gwProof
    ) external onlyGuildAdmin whenNotPaused returns (uint256 id) {
        euint64 tokenContrib = FHE.fromExternal(encTokenContrib, tcProof);
        euint32 contribScore = FHE.fromExternal(encContribScore, csProof);
        euint16 govWeight = FHE.fromExternal(encGovWeight, gwProof);
        id = memberCount++;
        memberIndex[memberAddress] = id;
        members[id] = GuildMember({
            memberAddress: memberAddress, rank: rank, tokenContributionUSD: tokenContrib,
            scholarshipEarningsUSD: FHE.asEuint64(0), tournamentRevenueUSD: FHE.asEuint64(0),
            contributionScore: contribScore, governanceWeightBps: govWeight,
            joinedAt: block.timestamp, active: true
        });
        _totalTreasuryUSD = FHE.add(_totalTreasuryUSD, tokenContrib);
        FHE.allowThis(members[id].tokenContributionUSD); FHE.allow(members[id].tokenContributionUSD, memberAddress);
        FHE.allowThis(members[id].scholarshipEarningsUSD); FHE.allow(members[id].scholarshipEarningsUSD, memberAddress);
        FHE.allowThis(members[id].tournamentRevenueUSD); FHE.allow(members[id].tournamentRevenueUSD, memberAddress);
        FHE.allowThis(members[id].contributionScore); FHE.allow(members[id].contributionScore, memberAddress);
        FHE.allowThis(members[id].governanceWeightBps); FHE.allow(members[id].governanceWeightBps, memberAddress);
        FHE.allowThis(_totalTreasuryUSD);
        emit MemberEnrolled(id, rank);
    }

    function recordScholarshipEarning(
        address memberAddress,
        externalEuint64 encEarnings, bytes calldata proof
    ) external onlyGuildAdmin {
        uint256 id = memberIndex[memberAddress];
        GuildMember storage m = members[id];
        euint64 earnings = FHE.fromExternal(encEarnings, proof);
        m.scholarshipEarningsUSD = FHE.add(m.scholarshipEarningsUSD, earnings);
        _totalScholarshipPaidUSD = FHE.add(_totalScholarshipPaidUSD, earnings);
        FHE.allowThis(m.scholarshipEarningsUSD); FHE.allow(m.scholarshipEarningsUSD, memberAddress);
        FHE.allowThis(_totalScholarshipPaidUSD);
    }

    function createProposal(
        string calldata description,
        externalEuint64 encRequestedAmt, bytes calldata proof,
        uint256 votingDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 requestedAmt = FHE.fromExternal(encRequestedAmt, proof);
        id = proposalCount++;
        proposals[id] = TreasuryProposal({
            proposer: msg.sender, description: description, requestedAmountUSD: requestedAmt,
            votesFor: FHE.asEuint64(0), votesAgainst: FHE.asEuint64(0), voterCount: 0,
            status: ProposalStatus.Active, createdAt: block.timestamp,
            votingEnd: block.timestamp + votingDays * 1 days
        });
        FHE.allowThis(proposals[id].requestedAmountUSD); FHE.allow(proposals[id].requestedAmountUSD, msg.sender);
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        emit ProposalCreated(id, msg.sender);
    }

    function voteOnProposal(
        uint256 proposalId, bool voteFor,
        externalEuint64 encVoteWeight, bytes calldata proof
    ) external whenNotPaused {
        TreasuryProposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active && block.timestamp < p.votingEnd, "Not active");
        euint64 weight = FHE.fromExternal(encVoteWeight, proof);
        if (voteFor) {
            p.votesFor = FHE.add(p.votesFor, weight);
            FHE.allowThis(p.votesFor);
        } else {
            p.votesAgainst = FHE.add(p.votesAgainst, weight);
            FHE.allowThis(p.votesAgainst);
        }
        p.voterCount++;
    }

    function executeProposal(uint256 proposalId) external onlyGuildAdmin nonReentrant {
        TreasuryProposal storage p = proposals[proposalId];
        require(block.timestamp >= p.votingEnd && p.status == ProposalStatus.Active, "Not ended");
        ebool passed = FHE.gt(p.votesFor, p.votesAgainst);
        euint64 allocation = FHE.select(passed, p.requestedAmountUSD, FHE.asEuint64(0));
        _totalTreasuryUSD = FHE.sub(_totalTreasuryUSD, allocation);
        p.status = ProposalStatus.Executed;
        FHE.allowThis(_totalTreasuryUSD);
        emit ProposalExecuted(proposalId);
    }

    function allowTreasuryStats(address viewer) external onlyOwner {
        FHE.allow(_totalTreasuryUSD, viewer);
        FHE.allow(_totalScholarshipPaidUSD, viewer);
        FHE.allow(_totalTournamentRevenueUSD, viewer);
    }
}
