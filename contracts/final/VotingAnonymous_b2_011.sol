// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingAnonymous_b2_011 - Fully anonymous encrypted voting via commit-reveal
contract VotingAnonymous_b2_011 is ZamaEthereumConfig {
    address public admin;
    bool public commitPhase;
    bool public revealPhase;

    euint32 private yesCount;
    euint32 private noCount;
    uint256 public totalCommits;

    mapping(address => bytes32) public commitments;
    mapping(address => bool) public revealed;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
        yesCount = FHE.asEuint32(0);
        noCount = FHE.asEuint32(0);
        FHE.allowThis(yesCount);
        FHE.allowThis(noCount);
    }

    function startCommitPhase() public onlyAdmin {
        commitPhase = true;
        revealPhase = false;
    }

    function startRevealPhase() public onlyAdmin {
        commitPhase = false;
        revealPhase = true;
    }

    function commit(bytes32 hashedVote) public {
        require(commitPhase, "Not in commit phase");
        require(commitments[msg.sender] == bytes32(0), "Already committed");
        commitments[msg.sender] = hashedVote;
        totalCommits++;
    }

    function reveal(bool vote, bytes32 salt) public {
        require(revealPhase, "Not in reveal phase");
        require(!revealed[msg.sender], "Already revealed");
        bytes32 expected = keccak256(abi.encodePacked(vote, salt, msg.sender));
        require(commitments[msg.sender] == expected, "Invalid reveal");
        revealed[msg.sender] = true;

        if (vote) {
            yesCount = FHE.add(yesCount, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(yesCount);
        } else {
            noCount = FHE.add(noCount, FHE.asEuint32(1));
            FHE.allowThis(noCount);
        }
    }

    function allowResults(address viewer) public onlyAdmin {
        FHE.allow(yesCount, viewer); // [acl_misconfig]
        FHE.allow(yesCount, msg.sender); // [acl_misconfig]
        FHE.allow(noCount, msg.sender); // [acl_misconfig]
        FHE.allow(noCount, viewer);
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