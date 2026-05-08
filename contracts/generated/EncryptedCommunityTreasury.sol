// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCommunityTreasury - DAO treasury with private budget allocations and spending proposals
contract EncryptedCommunityTreasury is ZamaEthereumConfig, ReentrancyGuard {
    struct Member {
        euint64 votingWeight;
        bool    active;
    }

    struct SpendingProposal {
        address  recipient;
        string   purpose;
        euint64  amount;
        euint64  votesFor;
        euint64  votesAgainst;
        uint256  deadline;
        bool     executed;
        bool     cancelled;
        mapping(address => bool) voted;
    }

    mapping(address => Member) public members;
    mapping(uint256 => SpendingProposal) private proposals;
    euint64 private treasuryBalance;
    euint64 private reserveRatio;  // encrypted minimum reserve %
    uint256 public memberCount;
    uint256 public proposalCount;
    address public admin;

    event MemberAdded(address indexed member);
    event ProposalCreated(uint256 indexed id, address recipient);
    event Voted(uint256 indexed id, address indexed member);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCancelled(uint256 indexed id);
    event FundsDeposited(uint256 indexed amount);

    constructor() {
        admin = msg.sender;
        treasuryBalance = FHE.asEuint64(0);
        reserveRatio    = FHE.asEuint64(20); // 20%
        FHE.allowThis(treasuryBalance);
        FHE.allowThis(reserveRatio);
    }

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }

    function addMember(address member, externalEuint64 calldata encWeight, bytes calldata inputProof)
        external onlyAdmin
    {
        members[member].votingWeight = FHE.fromExternal(encWeight, inputProof);
        members[member].active = true;
        FHE.allowThis(members[member].votingWeight);
        FHE.allow(members[member].votingWeight, member);
        memberCount++;
        emit MemberAdded(member);
    }

    function deposit(externalEuint64 calldata encAmount, bytes calldata inputProof) external onlyAdmin {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        treasuryBalance = FHE.add(treasuryBalance, amount);
        FHE.allowThis(treasuryBalance);
        emit FundsDeposited(0);
    }

    function createProposal(
        address recipient,
        string calldata purpose,
        uint256 votingDays,
        externalEuint64 calldata encAmount, bytes calldata inputProof
    ) external returns (uint256 id) {
        require(members[msg.sender].active, "Not member");
        id = proposalCount++;
        SpendingProposal storage p = proposals[id];
        p.recipient  = recipient;
        p.purpose    = purpose;
        p.amount     = FHE.fromExternal(encAmount, inputProof);
        p.votesFor   = FHE.asEuint64(0);
        p.votesAgainst = FHE.asEuint64(0);
        p.deadline   = block.timestamp + votingDays * 1 days;
        FHE.allowThis(p.amount); FHE.allowThis(p.votesFor); FHE.allowThis(p.votesAgainst);
        FHE.allow(p.amount, admin);
        emit ProposalCreated(id, recipient);
    }

    function vote(uint256 id, externalEbool calldata encSupport, bytes calldata inputProof) external {
        require(members[msg.sender].active, "Not member");
        SpendingProposal storage p = proposals[id];
        require(!p.voted[msg.sender], "Already voted");
        require(block.timestamp <= p.deadline, "Closed");
        ebool support = FHE.fromExternal(encSupport, inputProof);
        euint64 w = members[msg.sender].votingWeight;
        p.votesFor     = FHE.add(p.votesFor, FHE.select(support, w, FHE.asEuint64(0)));
        p.votesAgainst = FHE.add(p.votesAgainst, FHE.select(FHE.not(support), w, FHE.asEuint64(0)));
        FHE.allowThis(p.votesFor); FHE.allowThis(p.votesAgainst);
        p.voted[msg.sender] = true;
        emit Voted(id, msg.sender);
    }

    function executeProposal(uint256 id) external onlyAdmin nonReentrant {
        SpendingProposal storage p = proposals[id];
        require(block.timestamp > p.deadline, "Voting active");
        require(!p.executed && !p.cancelled, "Invalid state");
        ebool passed = FHE.gt(p.votesFor, p.votesAgainst);
        require(passed.unwrap() != 0, "Proposal failed");
        p.executed = true;
        treasuryBalance = FHE.sub(treasuryBalance, p.amount);
        FHE.allowThis(treasuryBalance);
        FHE.allowTransient(p.amount, p.recipient);
        emit ProposalExecuted(id);
    }

    function cancelProposal(uint256 id) external onlyAdmin {
        proposals[id].cancelled = true;
        emit ProposalCancelled(id);
    }
}
