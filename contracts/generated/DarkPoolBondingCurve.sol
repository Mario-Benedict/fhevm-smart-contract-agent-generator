// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DarkPoolBondingCurve is ZamaEthereumConfig, ERC20 {
    uint256 public constant BASE_PRICE = 100; // base price in wei
    uint256 public constant SLOPE = 10; // increase per token

    struct HiddenOrder {
        euint64 encryptedTokensDesired;
        euint64 encryptedMaxSpend;
        bool isActive;
    }

    mapping(address => HiddenOrder) private orders;
    
    constructor() ERC20("DarkCurve Token", "DCT") {}

    // Math for integral of linear bonding curve: P(x) = slope * x + base
    // Cost = slope/2 * (newSupply^2 - oldSupply^2) + base * tokensDesired
    function getCurrentPrice() public view returns (uint256) {
        return (totalSupply() * SLOPE) + BASE_PRICE;
    }

    function placeEncryptedBuyOrder(
        externalEuint64 memory extTokens,
        externalEuint64 memory extMaxSpend,
        bytes calldata proofTokens,
        bytes calldata proofSpend
    ) external payable {
        euint64 tokens = FHE.fromExternal(extTokens, proofTokens);
        euint64 spend = FHE.fromExternal(extMaxSpend, proofSpend);
        
        FHE.allowThis(tokens);
        FHE.allowThis(spend);

        // Pre-fund the contract with plaintext ETH
        require(msg.value > 0, "Must send ETH");

        orders[msg.sender] = HiddenOrder(tokens, spend, true);
    }

    // Executed by keeper. Converts the user's hidden constraints into reality.
    function executeOrder(address buyer) external {
        HiddenOrder storage order = orders[buyer];
        require(order.isActive, "No order");

        // Calculate simple cost based on current spot price to avoid complex FHE integral math
        // Cost = tokensDesired * currentPrice (approximation for medium complexity)
        uint64 spotPrice = uint64(getCurrentPrice());
        euint64 encSpotPrice = FHE.asEuint64(spotPrice);
        
        euint64 totalCost = FHE.mul(order.encryptedTokensDesired, encSpotPrice);
        FHE.allowThis(totalCost);

        // Condition: totalCost <= encryptedMaxSpend
        ebool conditionMet = FHE.le(totalCost, order.encryptedMaxSpend);
        FHE.req(conditionMet); // Reverts if user's max spend is too low

        // If condition passes, decrypt exact token amount to mint
        uint64 tokensToMint = FHE.decrypt(order.encryptedTokensDesired);
        
        order.isActive = false;
        _mint(buyer, tokensToMint);
    }
}