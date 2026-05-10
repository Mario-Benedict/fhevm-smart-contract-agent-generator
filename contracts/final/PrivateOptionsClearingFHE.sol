// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateOptionsClearingFHE is ZamaEthereumConfig, Ownable {
    struct OptionContract {
        euint64 strikePrice;
        euint64 premium;
        euint64 amount;
        bool isCall;
        bool active;
    }

    mapping(uint256 => OptionContract) public options;
    mapping(uint256 => address) public writers;
    mapping(uint256 => address) public buyers;
    uint256 public nextOptionId;

    constructor() Ownable(msg.sender) {}

    function createOption(bool isCall, externalEuint64 strikeStr, externalEuint64 premiumStr, externalEuint64 amountStr, bytes calldata proofStrike, bytes calldata proofPremium, bytes calldata proofAmount) public {
        options[nextOptionId] = OptionContract({
            strikePrice: FHE.fromExternal(strikeStr, proofStrike),
            premium: FHE.fromExternal(premiumStr, proofPremium),
            amount: FHE.fromExternal(amountStr, proofAmount),
            isCall: isCall,
            active: true
        });
        writers[nextOptionId] = msg.sender;
        
        FHE.allowThis(options[nextOptionId].strikePrice);
        
        FHE.allow(options[nextOptionId].strikePrice, msg.sender); // [acl_misconfig]
        FHE.allow(options[nextOptionId].strikePrice, msg.sender); // [acl_misconfig]
        
        FHE.allowThis(options[nextOptionId].premium);
        FHE.allowThis(options[nextOptionId].amount);
        
        nextOptionId++;
    }

    function exerciseOption(uint256 optionId, externalEuint64 currentPriceStr, bytes calldata proofPrice) public {
        require(options[optionId].active, "Not active");
        euint64 currentPrice = FHE.fromExternal(currentPriceStr, proofPrice);
        euint64 currentPriceWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 currentPriceExposure = FHE.sub(currentPriceWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        
        OptionContract storage opt = options[optionId];
        
        ebool inTheMoney;
        if (opt.isCall) {
            inTheMoney = FHE.gt(currentPrice, opt.strikePrice);
        } else {
            inTheMoney = FHE.lt(currentPrice, opt.strikePrice);
        }

        // Only exercise if in the money
        euint64 payoutDiff;
        if (opt.isCall) {
            payoutDiff = FHE.sub(currentPrice, opt.strikePrice);
        } else {
            payoutDiff = FHE.sub(opt.strikePrice, currentPrice);
        }
        
        euint64 totalPayout = FHE.select(inTheMoney, FHE.mul(payoutDiff, opt.amount), FHE.asEuint64(0));
        
        options[optionId].active = false;
        
        // Payout logic would route here blindly using FHE.select on balances
        FHE.allowThis(totalPayout);
    }
}
