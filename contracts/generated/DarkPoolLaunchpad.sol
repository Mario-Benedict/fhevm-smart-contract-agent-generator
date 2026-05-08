// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DarkPoolLaunchpad is ZamaEthereumConfig, ERC20, Ownable {
    struct EncryptedOrder {
        euint64 encryptedBidAmount;
        euint64 encryptedMaxPrice;
        bool isActive;
    }

    mapping(address => EncryptedOrder) private orders;
    euint64 private currentMarketPrice;
    
    event OrderPlaced(address indexed trader);
    event OrderFilled(address indexed trader);

    constructor() ERC20("DarkPool Asset", "DPA") Ownable(msg.sender) {
        // Mint initial supply to the pool
        _mint(address(this), 1000000 * 10 ** decimals());
        
        // Initialize an encrypted market price (e.g., set by Oracle or Admin)
        currentMarketPrice = FHE.asEuint64(100); 
        FHE.allowThis(currentMarketPrice);
    }

    // Admin updates the encrypted market clearing price
    function updateMarketPrice(
        externalEuint64 memory extPrice,
        bytes calldata inputProof
    ) external onlyOwner {
        currentMarketPrice = FHE.fromExternal(extPrice, inputProof);
        FHE.allowThis(currentMarketPrice);
    }

    // User submits an encrypted bid and maximum acceptable price
    function placeEncryptedLimitOrder(
        externalEuint64 memory extBidAmount,
        externalEuint64 memory extMaxPrice,
        bytes calldata proofAmount,
        bytes calldata proofPrice
    ) external {
        euint64 bidAmount = FHE.fromExternal(extBidAmount, proofAmount);
        euint64 maxPrice = FHE.fromExternal(extMaxPrice, proofPrice);
        
        FHE.allowThis(bidAmount);
        FHE.allowThis(maxPrice);

        orders[msg.sender] = EncryptedOrder({
            encryptedBidAmount: bidAmount,
            encryptedMaxPrice: maxPrice,
            isActive: true
        });

        emit OrderPlaced(msg.sender);
    }

    // Keeper or Admin executes the trade if conditions are met
    function executeOrder(address trader) external onlyOwner {
        require(orders[trader].isActive, "No active order");

        EncryptedOrder storage order = orders[trader];

        // Check if market price is <= user's max price
        ebool priceConditionMet = FHE.le(currentMarketPrice, order.encryptedMaxPrice);
        
        // If condition met, calculate tokens to mint/transfer. If not, 0.
        // Simplified calculation: Tokens = BidAmount / MarketPrice
        euint64 tokensToReceive = FHE.div(order.encryptedBidAmount, currentMarketPrice);
        euint64 actualTransfer = FHE.select(priceConditionMet, tokensToReceive, FHE.asEuint64(0));
        FHE.allowThis(actualTransfer);

        // Require that the transfer is greater than 0 to proceed with the transaction
        ebool isTradeValid = FHE.gt(actualTransfer, FHE.asEuint64(0));
        FHE.req(isTradeValid);

        // Deactivate order
        order.isActive = false;

        // Decrypt the final transfer amount to handle the standard ERC20 transfer
        FHE.allow(actualTransfer, trader);
        
        // In a real execution, this would pull USDC from the user.
        // Here we just issue the standard ERC20 from the pool to the user.
        // The actual transfer happens post-decryption by a relayer.
        
        emit OrderFilled(trader);
    }
}