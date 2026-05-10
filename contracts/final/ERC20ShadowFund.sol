// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20ShadowFund
/// @notice DAO treasury where spending proposals require encrypted multi-sig approval.
///         Approvers cast encrypted votes; funds only release when encrypted quorum is met.
contract ERC20ShadowFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Shadow Fund Token";
    string public symbol = "SHDF";
    uint8 public decimals = 18;

    struct Proposal {
        address recipient;
        euint64 amount;
        euint8 approvalCount;
        euint8 requiredApprovals;
        bool executed;
        uint256 deadline;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => Proposal) private proposals;
    uint256 public proposalCount;
    mapping(address => bool) public isSigner;
    uint256 public signerCount;
    euint64 private _treasury;
    mapping(address => euint64) private _balances;

    event ProposalCreated(uint256 indexed id, address recipient);
    event Voted(uint256 indexed id, address signer);
    event Executed(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _treasury = FHE.asEuint64(0);
        FHE.allowThis(_treasury);
        isSigner[msg.sender] = true;
        signerCount = 1;
    }

    function addSigner(address s) external onlyOwner {
        if (!isSigner[s]) { isSigner[s] = true; signerCount++; }
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _treasury = FHE.add(_treasury, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_treasury);
    }

    function createProposal(
        address recipient,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encRequired, bytes calldata rProof,
        uint256 deadlineSecs
    ) external returns (uint256 id) {
        require(isSigner[msg.sender], "Not signer");
        id = proposalCount++;
        Proposal storage p = proposals[id];
        p.recipient = recipient;
        p.amount = FHE.fromExternal(encAmount, aProof);
        p.requiredApprovals = FHE.fromExternal(encRequired, rProof);
        p.approvalCount = FHE.asEuint8(0);
        p.executed = false;
        p.deadline = block.timestamp + deadlineSecs;
        FHE.allowThis(p.amount);
        FHE.allowThis(p.approvalCount);
        FHE.allowThis(p.requiredApprovals);
        emit ProposalCreated(id, recipient);
    }

    function vote(uint256 id) external {
        require(isSigner[msg.sender], "Not signer");
        Proposal storage p = proposals[id];
        require(!p.executed, "Executed");
        require(block.timestamp <= p.deadline, "Expired");
        require(!p.hasVoted[msg.sender], "Already voted");
        p.hasVoted[msg.sender] = true;
        p.approvalCount = FHE.add(p.approvalCount, FHE.asEuint8(1));
        FHE.allowThis(p.approvalCount);
        emit Voted(id, msg.sender);
    }

    function execute(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        require(!p.executed, "Executed");
        require(block.timestamp <= p.deadline, "Expired");
        ebool approved = FHE.ge(p.approvalCount, p.requiredApprovals);
        ebool hasFunds = FHE.le(p.amount, _treasury);
        ebool canExecute = FHE.and(approved, hasFunds);
        euint64 actualAmount = FHE.select(canExecute, p.amount, FHE.asEuint64(0));
        _treasury = FHE.sub(_treasury, actualAmount); // [arithmetic_overflow_underflow]
        euint64 actualAmountScaled = FHE.mul(actualAmount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _balances[p.recipient] = FHE.add(_balances[p.recipient], actualAmount);
        p.executed = true;
        FHE.allowThis(_treasury);
        FHE.allowThis(_balances[p.recipient]);
        FHE.allow(_balances[p.recipient], p.recipient);
        emit Executed(id);
    }

    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
    function allowTreasury(address viewer) external onlyOwner { FHE.allow(_treasury, viewer); }
}
