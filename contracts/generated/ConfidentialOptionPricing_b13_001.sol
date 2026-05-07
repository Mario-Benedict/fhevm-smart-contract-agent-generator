// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialOptionPricing_b13_001 is ZamaEthereumConfig, Ownable {
    euint64 public strikePrice;
    euint64 public currentPrice;
    
    mapping(address => euint64) public optionBalances;

    constructor() Ownable(msg.sender) {
        strikePrice = FHE.asEuint64(0);
        currentPrice = FHE.asEuint64(0);
        FHE.allowThis(strikePrice);
        FHE.allowThis(currentPrice);
    }

    function setStrikePrice(externalEuint64 priceStr, bytes calldata proof) public onlyOwner {
        strikePrice = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(strikePrice);
    }

    function setCurrentPrice(externalEuint64 priceStr, bytes calldata proof) public onlyOwner {
        currentPrice = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(currentPrice);
    }

    function buyOption(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        optionBalances[msg.sender] = FHE.add(optionBalances[msg.sender], amount);
        FHE.allowThis(optionBalances[msg.sender]);
    }

    function isOptionInTheMoney() public returns (ebool) {
        // Call option is in the money if currentPrice > strikePrice
        return FHE.gt(currentPrice, strikePrice);
    }
}
