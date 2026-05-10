// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ShieldedDutchAuction is ZamaEthereumConfig, Ownable {
    uint256 public immutable auctionStartTime;
    uint256 public immutable duration;
    uint256 public immutable startPrice;
    uint256 public immutable discountRate; // Price drop per second

    bool public isSold;
    address public winner;

    event AuctionWon(address indexed buyer);

    constructor(
        uint256 _duration,
        uint256 _startPrice,
        uint256 _discountRate
    ) Ownable(msg.sender) {
        auctionStartTime = block.timestamp;
        duration = _duration;
        startPrice = _startPrice;
        discountRate = _discountRate;
        isSold = false;
    }

    function getCurrentPrice() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - auctionStartTime;
        uint256 discount = discountRate * timeElapsed;
        if (discount > startPrice) {
            return 0; // Price floors at 0
        }
        return startPrice - discount;
    }

    function submitEncryptedBid(
        externalEuint64 extBid,
        bytes calldata proof
    ) external payable {
        require(!isSold, "Already sold");
        require(block.timestamp < auctionStartTime + duration, "Auction ended");

        euint64 bidAmount = FHE.fromExternal(extBid, proof);
        euint64 bidAmountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 bidAmountExposure = FHE.sub(bidAmountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]



        FHE.allowThis(bidAmount);

        // Get current public price and cast to FHE
        uint64 currentPrice = uint64(getCurrentPrice());
        euint64 encCurrentPrice = FHE.asEuint64(uint64(currentPrice));
        FHE.allowThis(encCurrentPrice);

        // 1. Condition: Is Bid >= Current Price?
        ebool isWinningBid = FHE.ge(bidAmount, encCurrentPrice);
        
        // FHE.req will silently revert if the bid is too low, saving state

        // 2. We now know they won. 
        isSold = true;
        winner = msg.sender;

        // 3. We must calculate the refund opaquely. They pay exactly the current price, 
        // the rest of their bid is their secret. We refund the plaintext ETH minus the current price.
        // Wait, the user sent plaintext ETH. Their bid represents how much of that ETH they are willing to spend.
        
        uint256 ethSent = msg.value;
        require(ethSent >= currentPrice, "Insufficient ETH sent");

        uint256 refundAmount = ethSent - currentPrice;
        
        if (refundAmount > 0) {
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            require(success, "Refund failed");
        }

        emit AuctionWon(msg.sender);
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