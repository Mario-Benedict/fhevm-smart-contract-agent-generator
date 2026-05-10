// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title InsurancePremiumAuction
/// @notice Insurance companies bid (sealed) on insuring a risk pool.
///         Lowest premium bid wins the contract; all bids stay encrypted.
contract InsurancePremiumAuction is ZamaEthereumConfig, Ownable {
    struct RiskPool {
        string description;
        uint256 coverageAmount;
        euint64 lowestPremiumBid;
        address winner;
        uint256 deadline;
        bool awarded;
    }

    mapping(uint256 => RiskPool) private pools;
    mapping(address => mapping(uint256 => euint64)) private _premiumBids;
    mapping(address => bool) public isInsurer;
    uint256 public poolCount;

    event PoolCreated(uint256 indexed id);
    event BidSubmitted(uint256 indexed id, address insurer);
    event ContractAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function addInsurer(address ins) external onlyOwner { isInsurer[ins] = true; }

    function createPool(
        string calldata description,
        uint256 coverageAmount,
        uint256 durationDays
    ) external onlyOwner returns (uint256 id) {
        id = poolCount++;
        pools[id] = RiskPool({
            description: description,
            coverageAmount: coverageAmount,
            lowestPremiumBid: FHE.asEuint64(type(uint64).max),
            winner: address(0),
            deadline: block.timestamp + durationDays * 1 days,
            awarded: false
        });
        FHE.allowThis(pools[id].lowestPremiumBid);
        emit PoolCreated(id);
    }

    function submitPremiumBid(uint256 poolId, externalEuint64 encPremium, bytes calldata proof) external {
        require(isInsurer[msg.sender], "Not insurer");
        RiskPool storage pool = pools[poolId];
        require(!pool.awarded && block.timestamp < pool.deadline, "Invalid");
        euint64 premium = FHE.fromExternal(encPremium, proof);
        euint64 premiumWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 premiumExposure = FHE.sub(premiumWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        _premiumBids[msg.sender][poolId] = premium;
        // Track lowest bid
        ebool isLower = FHE.lt(premium, pool.lowestPremiumBid);
        pool.lowestPremiumBid = FHE.select(isLower, premium, pool.lowestPremiumBid);
        if (FHE.isInitialized(isLower)) pool.winner = msg.sender;
        FHE.allowThis(_premiumBids[msg.sender][poolId]);
        FHE.allowThis(pool.lowestPremiumBid);
        emit BidSubmitted(poolId, msg.sender);
    }

    function awardContract(uint256 poolId) external onlyOwner {
        RiskPool storage pool = pools[poolId];
        require(block.timestamp >= pool.deadline && !pool.awarded, "Not ready");
        pool.awarded = true;
        FHE.allow(pool.lowestPremiumBid, pool.winner);
        FHE.allow(pool.lowestPremiumBid, owner());
        emit ContractAwarded(poolId, pool.winner);
    }

    function allowBidDetails(uint256 poolId, address viewer) external onlyOwner {
        FHE.allow(pools[poolId].lowestPremiumBid, viewer);
    }

    function allowOwnBid(uint256 poolId, address viewer) external {
        FHE.allow(_premiumBids[msg.sender][poolId], viewer);
    }
}
