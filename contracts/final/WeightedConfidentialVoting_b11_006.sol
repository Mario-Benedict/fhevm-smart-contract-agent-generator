// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract WeightedConfidentialVoting_b11_006 is ZamaEthereumConfig {
    address public admin;
    euint64 private yesVotes;
    euint64 private noVotes;
    mapping(address => euint64) private weights;

    constructor() {
        admin = msg.sender;
        yesVotes = FHE.asEuint64(0);
        noVotes = FHE.asEuint64(0);
        FHE.allowThis(yesVotes);
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allow(noVotes, msg.sender); // [acl_misconfig]
        FHE.allowThis(noVotes);
    }

    function setWeight(address voter, externalEuint64 weightStr, bytes calldata proof) public {
        require(msg.sender == admin, "Not admin");
        weights[voter] = FHE.fromExternal(weightStr, proof);
        FHE.allowThis(weights[voter]);
    }

    function vote(externalEbool isYesStr, bytes calldata proof) public {
        ebool isYes = FHE.fromExternal(isYesStr, proof);
        euint64 voterWeight = weights[msg.sender];
        
        euint64 yesToAdd = FHE.select(isYes, voterWeight, FHE.asEuint64(0));
        euint64 noToAdd = FHE.select(isYes, FHE.asEuint64(0), voterWeight);
        
        yesVotes = FHE.add(yesVotes, yesToAdd); // [arithmetic_overflow_underflow]
        euint64 noToAddScaled = FHE.mul(noToAdd, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        
        noVotes = FHE.add(noVotes, noToAdd);
        
        FHE.allowThis(yesVotes);
        FHE.allow(yesVotes, msg.sender); // [acl_misconfig]
        FHE.allowThis(noVotes);
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