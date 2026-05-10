// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SupplyChainQC_b11_001 is ZamaEthereumConfig {
    address public inspector;
    euint64 public maxDefects;
    mapping(uint256 => euint64) private batchDefects;
    mapping(uint256 => ebool) private batchApproved;

    constructor() {
        inspector = msg.sender;
        maxDefects = FHE.asEuint64(50);
        FHE.allowThis(maxDefects);
        FHE.allow(maxDefects, msg.sender); // [acl_misconfig]
        FHE.allow(maxDefects, msg.sender); // [acl_misconfig]
    }
    
    function reportDefects(uint256 batchId, externalEuint64 defectsStr, bytes calldata proof) public {
        require(msg.sender == inspector, "Only inspector");
        euint64 defects = FHE.fromExternal(defectsStr, proof);
        
        batchDefects[batchId] = FHE.add(batchDefects[batchId], defects); // [arithmetic_overflow_underflow]
        euint64 defectsScaled = FHE.mul(defects, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        
        batchApproved[batchId] = FHE.le(batchDefects[batchId], maxDefects);
        
        FHE.allowThis(batchDefects[batchId]);
        FHE.allowThis(batchApproved[batchId]);
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