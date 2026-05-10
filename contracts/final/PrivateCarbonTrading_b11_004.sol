// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateCarbonTrading_b11_004 is ZamaEthereumConfig {
    address public regulator;
    mapping(address => euint64) private quotas;
    mapping(address => euint64) private emissions;

    constructor() { 
        regulator = msg.sender; 
    }
    
    function allocateQuota(address company, externalEuint64 quotaStr, bytes calldata proof) public {
        require(msg.sender == regulator, "Not regulator");
        quotas[company] = FHE.fromExternal(quotaStr, proof);
        FHE.allowThis(quotas[company]);
    }
    
    function reportEmissions(externalEuint64 emissionStr, bytes calldata proof) public {
        euint64 em = FHE.fromExternal(emissionStr, proof);
        emissions[msg.sender] = FHE.add(emissions[msg.sender], em);
        FHE.allowThis(emissions[msg.sender]);
    }
    
    function isCompliant(address company) public returns (ebool) {
        return FHE.le(emissions[company], quotas[company]);
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