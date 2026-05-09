// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedDutchAuction_b9_003 is ZamaEthereumConfig {
    address public seller;
    euint64 private startPrice;
    euint64 private discountRate; 
    uint256 public startTime;
    
    ebool private isSold;
    mapping(address => euint64) private balances;

    constructor() {
        seller = msg.sender;
        isSold = FHE.asEbool(false);
        FHE.allowThis(isSold);
    }

    function initAuction(externalEuint64 sPriceStr, externalEuint64 discountStr, bytes calldata proofP, bytes calldata proofD) public {
        require(msg.sender == seller, "Only seller");
        startPrice = FHE.fromExternal(sPriceStr, proofP);
        discountRate = FHE.fromExternal(discountStr, proofD);
        startTime = block.timestamp;
        FHE.allowThis(startPrice);
        FHE.allowThis(discountRate);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        FHE.allowThis(balances[msg.sender]);
    }

    function buy() public {
        require(startTime > 0, "Not started");
        
        uint256 elapsed = block.timestamp - startTime;
        
        euint64 discount = FHE.mul(discountRate, FHE.asEuint64(uint64(elapsed)));
        
        // Prevent underflow if discount exceeds startPrice
        ebool positivePrice = FHE.ge(startPrice, discount);
        euint64 currentPrice = FHE.select(positivePrice, FHE.sub(startPrice, discount), FHE.asEuint64(0));

        ebool canAfford = FHE.ge(balances[msg.sender], currentPrice);
        ebool available = FHE.not(isSold);
        
        ebool execute = FHE.and(canAfford, available);

        euint64 actualPay = FHE.select(execute, currentPrice, FHE.asEuint64(0));

        balances[msg.sender] = FHE.sub(balances[msg.sender], actualPay);
        balances[seller] = FHE.add(balances[seller], actualPay);

        isSold = FHE.select(execute, FHE.asEbool(true), isSold);

        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[seller]);
        FHE.allowThis(isSold);
    }
}
