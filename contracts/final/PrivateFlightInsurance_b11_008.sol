// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateFlightInsurance_b11_008 is ZamaEthereumConfig {
    address public oracle;
    euint64 public delayThreshold; // e.g., minutes
    euint64 public payoutAmount;
    mapping(address => euint64) private pendingPayouts;

    constructor() {
        oracle = msg.sender;
        delayThreshold = FHE.asEuint64(120); 
        payoutAmount = FHE.asEuint64(5000);
        FHE.allowThis(delayThreshold);
        FHE.allowThis(payoutAmount);
    }

    function reportDelay(address user, externalEuint64 delayStr, bytes calldata proof) public {
        require(msg.sender == oracle, "Not oracle");
        euint64 delay = FHE.fromExternal(delayStr, proof);
        ebool isDelayed = FHE.ge(delay, delayThreshold);
        
        euint64 payout = FHE.select(isDelayed, payoutAmount, FHE.asEuint64(0));
        pendingPayouts[user] = FHE.add(pendingPayouts[user], payout);
        FHE.allowThis(pendingPayouts[user]);
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