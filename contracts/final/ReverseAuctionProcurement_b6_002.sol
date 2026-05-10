// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ReverseAuctionProcurement_b6_002 is ZamaEthereumConfig {
    address public procurementOfficer;
    
    euint64 private lowestBid;
    address public winningBidder; // Known winner after reveal, but we will keep bids hidden during process
    mapping(address => euint64) private bids;

    bool public isAuctionOpen;

    constructor() {
        procurementOfficer = msg.sender;
        // Init with highest possible 64-bit value to allow minimums
        lowestBid = FHE.asEuint64(18446744073709551615); 
        FHE.allowThis(lowestBid);
        isAuctionOpen = true;
    }

    function submitBid(externalEuint64 bidAmountStr, bytes calldata proof) public {
        require(isAuctionOpen, "Auction closed");
        euint64 amount = FHE.fromExternal(bidAmountStr, proof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        bids[msg.sender] = amount;
        FHE.allowThis(bids[msg.sender]);

        // Evaluate if this is the new lowest bid
        ebool isLower = FHE.lt(amount, lowestBid);
        lowestBid = FHE.select(isLower, amount, lowestBid);
        FHE.allowThis(lowestBid);

        // Note: For fully blind evaluation without leaking the winner real-time, 
        // we wouldn't update plaintext `winningBidder` conditionally. We just keep lowestBid hidden.
    }

    function closeAuction() public {
        require(msg.sender == procurementOfficer, "Not authorized");
        isAuctionOpen = false;
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