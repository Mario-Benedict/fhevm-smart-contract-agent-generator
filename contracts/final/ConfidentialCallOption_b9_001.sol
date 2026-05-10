// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialCallOption_b9_001 is ZamaEthereumConfig {
    address public writer;
    address public buyer;

    euint64 private strikePrice;
    euint64 private premium;
    ebool private isPurchased;
    ebool private isExercised;
    uint256 public expiry;

    mapping(address => euint64) private balances;

    constructor(uint256 duration) {
        writer = msg.sender;
        expiry = block.timestamp + duration;
        // Initialize booleans
        isPurchased = FHE.asEbool(false);
        isExercised = FHE.asEbool(false);
        FHE.allowThis(isPurchased);
        FHE.allowThis(isExercised);
    }

    function createOption(externalEuint64 strikeStr, externalEuint64 premiumStr, bytes calldata proofS, bytes calldata proofP) public {
        require(msg.sender == writer, "Only writer");
        strikePrice = FHE.fromExternal(strikeStr, proofS);
        premium = FHE.fromExternal(premiumStr, proofP);
        FHE.allowThis(strikePrice);
        FHE.allowThis(premium);
    }

    // abstract token deposit
    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        FHE.allowThis(balances[msg.sender]);
    }

    function buyOption() public {
        require(msg.sender != writer, "Writer cannot buy");
        require(buyer == address(0), "Already bought");
        
        ebool canAfford = FHE.ge(balances[msg.sender], premium);
        
        euint64 actualPremium = FHE.select(canAfford, premium, FHE.asEuint64(0));
        ebool _safeSub20 = FHE.ge(balances[msg.sender], actualPremium);
        balances[msg.sender] = FHE.select(_safeSub20, FHE.sub(balances[msg.sender], actualPremium), FHE.asEuint64(0));
        balances[writer] = FHE.add(balances[writer], actualPremium);
        
        isPurchased = FHE.select(canAfford, FHE.asEbool(true), isPurchased);
        FHE.allowThis(isPurchased);

        buyer = msg.sender; 
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[writer]);
    }

    function exerciseOption() public {
        require(msg.sender == buyer, "Only buyer");
        require(block.timestamp <= expiry, "Expired");
        
        ebool canAfford = FHE.ge(balances[msg.sender], strikePrice);
        ebool validExercise = FHE.and(canAfford, isPurchased);
        ebool notYetExercised = FHE.not(isExercised);
        ebool execute = FHE.and(validExercise, notYetExercised);

        euint64 actualStrike = FHE.select(execute, strikePrice, FHE.asEuint64(0));

        ebool _safeSub21 = FHE.ge(balances[msg.sender], actualStrike);
        balances[msg.sender] = FHE.select(_safeSub21, FHE.sub(balances[msg.sender], actualStrike), FHE.asEuint64(0));
        balances[writer] = FHE.add(balances[writer], actualStrike);

        isExercised = FHE.select(execute, FHE.asEbool(true), isExercised);
        
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[writer]);
        FHE.allowThis(isExercised);
    }
}
