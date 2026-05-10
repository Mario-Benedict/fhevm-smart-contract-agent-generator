// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindEscrow_b7_003 is ZamaEthereumConfig {
    address public buyer;
    address public seller;
    address public arbiter;

    euint64 private escrowFunds;
    euint8 private escrowState; // 0 = PENDING, 1 = RELEASE_TO_SELLER, 2 = REFUND_BUYER

    constructor(address _seller, address _arbiter) {
        buyer = msg.sender;
        seller = _seller;
        arbiter = _arbiter;
        escrowFunds = FHE.asEuint64(0);
        escrowState = FHE.asEuint8(0);
        
        FHE.allowThis(escrowFunds);
        FHE.allowThis(escrowState);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        require(msg.sender == buyer, "Only buyer");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        escrowFunds = FHE.add(escrowFunds, amount);
        FHE.allowThis(escrowFunds);
    }

    function resolveDispute(externalEuint8 outcomeStr, bytes calldata proof) public {
        require(msg.sender == arbiter, "Only arbiter");
        euint8 outcome = FHE.fromExternal(outcomeStr, proof);
        
        // outcome should be 1 (seller) or 2 (buyer)
        escrowState = outcome;
        FHE.allowThis(escrowState);
    }

    function claimFunds() public {
        // Evaluate state
        ebool isSellerWin = FHE.eq(escrowState, FHE.asEuint8(1));
        ebool isBuyerWin = FHE.eq(escrowState, FHE.asEuint8(2));

        euint64 fundsToSeller = FHE.select(isSellerWin, escrowFunds, FHE.asEuint64(0));
        euint64 fundsToBuyer = FHE.select(isBuyerWin, escrowFunds, FHE.asEuint64(0));

        // Securely empty escrow only if a decision was made
        ebool isResolved = FHE.or(isSellerWin, isBuyerWin);
        escrowFunds = FHE.select(isResolved, FHE.asEuint64(0), escrowFunds);
        
        FHE.allowThis(escrowFunds);
        FHE.allowThis(fundsToSeller);
        FHE.allowThis(fundsToBuyer);
    }
}
