// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivateGrantDAO_c2_018
/// @notice DAO that manages an encrypted grant treasury; members vote privately
///         on grant proposals with encrypted vote weights.
contract ERC20PrivateGrantDAO_c2_018 is ZamaEthereumConfig, Ownable {
    string public name = "Grant DAO Token";
    string public symbol = "GDT";

    struct Proposal {
        address recipient;
        euint64 requestedAmount;
        euint64 votesFor;
        euint64 votesAgainst;
        uint256 deadline;
        bool executed;
    }

    euint64 private _treasury;
    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => bool) public isMember;
    Proposal[] public proposals;
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, address recipient);
    event Voted(uint256 indexed id, address voter);
    event ProposalExecuted(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _treasury = FHE.asEuint64(0);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_treasury);
        FHE.allowThis(_totalSupply);
        isMember[msg.sender] = true;
    }

    function addMember(address m) external onlyOwner { isMember[m] = true; }
    function removeMember(address m) external onlyOwner { isMember[m] = false; }

    function fundTreasury(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _treasury = FHE.add(_treasury, amount);
        FHE.allowThis(_treasury);
    }

    function mintToMember(address member, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        require(isMember[member], "Not member");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[member] = FHE.add(_balances[member], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[member]);
        FHE.allow(_balances[member], member);
        FHE.allowThis(_totalSupply);
    }

    function createProposal(address recipient, externalEuint64 encAmount, bytes calldata proof, uint256 durationDays)
        external returns (uint256)
    {
        require(isMember[msg.sender], "Not member");
        euint64 requested = FHE.fromExternal(encAmount, proof);
        uint256 id = proposals.length;
        proposals.push(Proposal({
            recipient: recipient,
            requestedAmount: requested,
            votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0),
            deadline: block.timestamp + durationDays * 1 days,
            executed: false
        }));
        FHE.allowThis(proposals[id].requestedAmount);
        FHE.allow(proposals[id].requestedAmount, owner());
        FHE.allowThis(proposals[id].votesFor);
        FHE.allowThis(proposals[id].votesAgainst);
        emit ProposalCreated(id, recipient);
        return id;
    }

    function vote(uint256 proposalId, bool support, externalEuint64 encWeight, bytes calldata proof) external {
        require(isMember[msg.sender], "Not member");
        require(!hasVoted[msg.sender][proposalId], "Already voted");
        require(block.timestamp < proposals[proposalId].deadline, "Deadline passed");
        hasVoted[msg.sender][proposalId] = true;
        euint64 weight = FHE.fromExternal(encWeight, proof);
        ebool ok = FHE.le(weight, _balances[msg.sender]);
        euint64 actualWeight = FHE.select(ok, weight, _balances[msg.sender]);
        Proposal storage p = proposals[proposalId];
        if (support) {
            p.votesFor = FHE.add(p.votesFor, actualWeight);
            FHE.allowThis(p.votesFor);
        } else {
            p.votesAgainst = FHE.add(p.votesAgainst, actualWeight);
            FHE.allowThis(p.votesAgainst);
        }
        emit Voted(proposalId, msg.sender);
    }

    function executeProposal(uint256 proposalId) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        require(!p.executed && block.timestamp >= p.deadline, "Cannot execute");
        p.executed = true;
        ebool passed = FHE.gt(p.votesFor, p.votesAgainst);
        ebool reserveOk = FHE.ge(_treasury, p.requestedAmount);
        ebool canPay = FHE.and(passed, reserveOk);
        euint64 payout = FHE.select(canPay, p.requestedAmount, FHE.asEuint64(0));
        _treasury = FHE.sub(_treasury, payout);
        FHE.allowThis(_treasury);
        FHE.allow(payout, p.recipient);
        emit ProposalExecuted(proposalId);
    }

    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
    function allowTreasury(address viewer) external onlyOwner { FHE.allow(_treasury, viewer); }
}
