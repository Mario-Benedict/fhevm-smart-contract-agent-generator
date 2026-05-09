// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiConfidentialBridge
/// @notice Cross-chain bridge with encrypted fee structures and hidden transfer amounts.
///         Relayers cannot see transaction amounts to prevent front-running.
///         Fee tiers are encrypted based on user loyalty scores.
contract DeFiConfidentialBridge is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct BridgeRequest {
        address sender;
        uint256 destChainId;
        euint64 amount;
        euint64 fee;
        euint8 userLoyaltyScore; // encrypted
        bytes32 commitment;      // hash commitment for verification
        bool processed;
        bool refunded;
    }

    mapping(uint256 => BridgeRequest) private requests;
    uint256 public requestCount;
    mapping(address => bool) public isRelayer;
    mapping(uint256 => euint64) private chainFeeBps; // encrypted fee per chain
    euint64 private _totalFeeCollected;
    euint64 private _loyaltyDiscountThreshold;

    event RequestSubmitted(uint256 indexed id, address sender, uint256 destChain);
    event RequestProcessed(uint256 indexed id);
    event RequestRefunded(uint256 indexed id);

    constructor(externalEuint64 encLoyaltyThreshold, bytes memory proof) Ownable(msg.sender) {
        _loyaltyDiscountThreshold = FHE.fromExternal(encLoyaltyThreshold, proof);
        _totalFeeCollected = FHE.asEuint64(0);
        FHE.allowThis(_loyaltyDiscountThreshold);
        FHE.allowThis(_totalFeeCollected);
        isRelayer[msg.sender] = true;
    }

    function addRelayer(address r) external onlyOwner { isRelayer[r] = true; }

    function setChainFee(uint256 chainId, externalEuint64 encFee, bytes calldata proof) external onlyOwner {
        chainFeeBps[chainId] = FHE.fromExternal(encFee, proof);
        FHE.allowThis(chainFeeBps[chainId]);
    }

    function submitBridgeRequest(
        uint256 destChainId,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encLoyalty, bytes calldata lProof,
        bytes32 commitment
    ) external nonReentrant returns (uint256 id) {
        id = requestCount++;
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint8 loyalty = FHE.fromExternal(encLoyalty, lProof);
        euint64 baseFee = FHE.div(FHE.mul(amount, chainFeeBps[destChainId]), 10000);
        // Apply 50% discount for high loyalty users
        ebool hasDiscount = FHE.ge(loyalty, _loyaltyDiscountThreshold);
        euint64 discountedFee = FHE.div(baseFee, 2);
        euint64 finalFee = FHE.select(hasDiscount, discountedFee, baseFee);
        requests[id] = BridgeRequest({
            sender: msg.sender, destChainId: destChainId,
            amount: amount, fee: finalFee,
            userLoyaltyScore: loyalty,
            commitment: commitment, processed: false, refunded: false
        });
        FHE.allowThis(requests[id].amount);
        FHE.allow(requests[id].amount, msg.sender);
        FHE.allowThis(requests[id].fee);
        FHE.allow(requests[id].fee, msg.sender);
        FHE.allowThis(requests[id].userLoyaltyScore);
        emit RequestSubmitted(id, msg.sender, destChainId);
    }

    function processRequest(uint256 id) external nonReentrant {
        require(isRelayer[msg.sender], "Not relayer");
        BridgeRequest storage req = requests[id];
        require(!req.processed && !req.refunded, "Already handled");
        req.processed = true;
        _totalFeeCollected = FHE.add(_totalFeeCollected, req.fee);
        FHE.allowThis(_totalFeeCollected);
        FHE.allow(req.amount, req.sender);
        emit RequestProcessed(id);
    }

    function refundRequest(uint256 id) external onlyOwner nonReentrant {
        BridgeRequest storage req = requests[id];
        require(!req.processed && !req.refunded, "Already handled");
        req.refunded = true;
        FHE.allow(req.amount, req.sender);
        emit RequestRefunded(id);
    }

    function allowBridgeStats(address viewer) external onlyOwner {
        FHE.allow(_totalFeeCollected, viewer);
    }
}
