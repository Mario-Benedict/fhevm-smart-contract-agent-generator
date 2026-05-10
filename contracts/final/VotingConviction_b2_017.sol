// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingConviction_b2_017 - Conviction voting where staked time amplifies votes
contract VotingConviction_b2_017 is ZamaEthereumConfig {
    address public admin;

    struct Proposal {
        string description;
        euint64 conviction;
        bool passed;
        uint256 threshold;
        uint256 createdAt;
    }

    Proposal[] public proposals;
    mapping(address => euint64) public stakedTokens;
    mapping(address => uint256) public stakeTimestamp;
    mapping(address => mapping(uint256 => bool)) public supporting;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        stakedTokens[msg.sender] = FHE.add(stakedTokens[msg.sender], amount);
        stakeTimestamp[msg.sender] = block.timestamp;
        FHE.allowThis(stakedTokens[msg.sender]);
    }

    function createProposal(string calldata description, uint256 threshold) public onlyAdmin returns (uint256) {
        uint256 id = proposals.length;
        proposals.push(Proposal({
            description: description,
            conviction: FHE.asEuint64(0),
            passed: false,
            threshold: threshold,
            createdAt: block.timestamp
        }));
        FHE.allowThis(proposals[id].conviction);
        return id;
    }

    function signalSupport(uint256 proposalId) public {
        require(proposalId < proposals.length, "Invalid proposal");
        require(!supporting[msg.sender][proposalId], "Already supporting");
        supporting[msg.sender][proposalId] = true;

        uint256 timeStaked = block.timestamp - stakeTimestamp[msg.sender];
        uint64 timeWeight = uint64(timeStaked / 1 days) + 1;
        euint64 conviction = FHE.mul(stakedTokens[msg.sender], FHE.asEuint64(uint64(timeWeight))); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        proposals[proposalId].conviction = FHE.add(proposals[proposalId].conviction, conviction);
        FHE.allowThis(proposals[proposalId].conviction);
    }

    function allowConviction(uint256 proposalId, address viewer) public onlyAdmin {
        FHE.allow(proposals[proposalId].conviction, viewer); // [acl_misconfig]
        FHE.allow(proposals[proposalId].conviction, msg.sender); // [acl_misconfig]
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