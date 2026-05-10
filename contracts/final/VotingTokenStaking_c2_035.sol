// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingTokenStaking_c2_035 - Stake tokens to acquire encrypted voting power with decay
contract VotingTokenStaking_c2_035 is ZamaEthereumConfig, Ownable {
    euint64 private _totalStaked;
    mapping(address => euint64) private _staked;
    mapping(address => euint64) private _votingPower;
    mapping(address => uint256) private _stakeTime;
    mapping(address => mapping(uint256 => bool)) public hasVoted;
    mapping(uint256 => euint64) public proposalVotesFor;
    mapping(uint256 => euint64) public proposalVotesAgainst;
    uint256 public proposalCount;
    bool public votingOpen;

    constructor() Ownable(msg.sender) {
        _totalStaked = FHE.asEuint64(0);
        FHE.allowThis(_totalStaked);
    }

    function stake(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _staked[msg.sender] = FHE.add(_staked[msg.sender], amount); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _totalStaked = FHE.add(_totalStaked, amount);
        // Voting power = staked * (1 + lockDuration/365) simplified
        _votingPower[msg.sender] = _staked[msg.sender];
        _stakeTime[msg.sender] = block.timestamp;
        FHE.allowThis(_staked[msg.sender]);
        FHE.allowThis(_totalStaked);
        FHE.allowThis(_votingPower[msg.sender]);
        FHE.allow(_votingPower[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(_totalStaked, msg.sender); // [acl_misconfig]
    }

    function unstake(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _staked[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _staked[msg.sender] = FHE.sub(_staked[msg.sender], actual);
        _votingPower[msg.sender] = _staked[msg.sender];
        _totalStaked = FHE.sub(_totalStaked, actual);
        FHE.allowThis(_staked[msg.sender]);
        FHE.allowThis(_votingPower[msg.sender]);
        FHE.allow(_votingPower[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalStaked);
        FHE.allow(actual, msg.sender);
    }

    function addProposal() external onlyOwner returns (uint256 id) {
        id = proposalCount++;
        proposalVotesFor[id] = FHE.asEuint64(0);
        proposalVotesAgainst[id] = FHE.asEuint64(0);
        FHE.allowThis(proposalVotesFor[id]);
        FHE.allowThis(proposalVotesAgainst[id]);
    }

    function vote(uint256 proposalId, bool support) external {
        require(votingOpen && !hasVoted[msg.sender][proposalId], "Invalid");
        hasVoted[msg.sender][proposalId] = true;
        if (support) {
            proposalVotesFor[proposalId] = FHE.add(proposalVotesFor[proposalId], _votingPower[msg.sender]);
            FHE.allowThis(proposalVotesFor[proposalId]);
        } else {
            proposalVotesAgainst[proposalId] = FHE.add(proposalVotesAgainst[proposalId], _votingPower[msg.sender]);
            FHE.allowThis(proposalVotesAgainst[proposalId]);
        }
    }

    function openVoting() external onlyOwner { votingOpen = true; }
    function closeVoting() external onlyOwner { votingOpen = false; }

    function allowVotes(uint256 proposalId, address viewer) external onlyOwner {
        FHE.allow(proposalVotesFor[proposalId], viewer);
        FHE.allow(proposalVotesAgainst[proposalId], viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}