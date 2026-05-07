// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateIntellectualPropertyMarket is ZamaEthereumConfig, Ownable {
    mapping(uint256 => euint64) public ipValuations;
    mapping(uint256 => address) public ipOwners;

    constructor() Ownable(msg.sender) {}

    function registerIP(uint256 ipId, externalEuint64 initialValStr, bytes calldata proof) public {
        require(ipOwners[ipId] == address(0), "IP Exists");
        ipOwners[ipId] = msg.sender;
        ipValuations[ipId] = FHE.fromExternal(initialValStr, proof);
        FHE.allowThis(ipValuations[ipId]);
    }

    function blindOffer(uint256 ipId, externalEuint64 offerStr, bytes calldata proof) public {
        require(ipOwners[ipId] != address(0), "No IP");
        euint64 offer = FHE.fromExternal(offerStr, proof);
        
        ebool offerAccepted = FHE.ge(offer, ipValuations[ipId]);
        
        // Conditional asset valuation update based on blind market interaction
        euint64 newValuation = FHE.select(offerAccepted, offer, ipValuations[ipId]);
        ipValuations[ipId] = newValuation;
        FHE.allowThis(ipValuations[ipId]);
    }
}
