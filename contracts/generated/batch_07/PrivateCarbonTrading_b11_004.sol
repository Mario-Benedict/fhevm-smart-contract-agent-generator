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
}
