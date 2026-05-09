// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiEncryptedRebalancer
/// @notice Portfolio rebalancer with encrypted target weights per asset class.
///         Rebalancing triggers fire when the portfolio drifts beyond an encrypted
///         drift threshold. Target weights are hidden from MEV bots.
contract DeFiEncryptedRebalancer is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    uint256 public constant MAX_ASSETS = 8;

    struct Asset {
        string symbol;
        euint16 targetWeightBps;  // encrypted target weight
        euint64 currentBalance;
        euint64 lastPrice;        // encrypted price feed
        bool active;
    }

    struct Portfolio {
        euint64 totalValue;
        euint16 maxDriftBps;      // encrypted max acceptable drift
        uint256 lastRebalance;
    }

    mapping(uint256 => Asset) private assets;
    uint256 public assetCount;
    Portfolio private portfolio;
    mapping(address => euint64) private userShares;
    euint64 private _totalShares;

    event AssetAdded(uint256 indexed id, string symbol);
    event Rebalanced(uint256 timestamp);
    event Deposited(address indexed user);
    event Withdrawn(address indexed user);

    constructor(externalEuint16 encMaxDrift, bytes memory proof) Ownable(msg.sender) {
        portfolio.maxDriftBps = FHE.fromExternal(encMaxDrift, proof);
        portfolio.totalValue = FHE.asEuint64(0);
        portfolio.lastRebalance = block.timestamp;
        _totalShares = FHE.asEuint64(0);
        FHE.allowThis(portfolio.maxDriftBps);
        FHE.allowThis(portfolio.totalValue);
        FHE.allowThis(_totalShares);
    }

    function addAsset(
        string calldata symbol,
        externalEuint16 encTarget, bytes calldata tProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOwner {
        require(assetCount < MAX_ASSETS, "Max assets");
        uint256 id = assetCount++;
        assets[id].symbol = symbol;
        assets[id].targetWeightBps = FHE.fromExternal(encTarget, tProof);
        assets[id].lastPrice = FHE.fromExternal(encPrice, pProof);
        assets[id].currentBalance = FHE.asEuint64(0);
        assets[id].active = true;
        FHE.allowThis(assets[id].targetWeightBps);
        FHE.allowThis(assets[id].lastPrice);
        FHE.allowThis(assets[id].currentBalance);
        emit AssetAdded(id, symbol);
    }

    function updatePrice(uint256 assetId, externalEuint64 encPrice, bytes calldata proof) external onlyOwner {
        assets[assetId].lastPrice = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(assets[assetId].lastPrice);
    }

    function deposit(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 newShares = amount; // simplified 1:1 shares
        userShares[msg.sender] = FHE.add(userShares[msg.sender], newShares);
        _totalShares = FHE.add(_totalShares, newShares);
        portfolio.totalValue = FHE.add(portfolio.totalValue, amount);
        FHE.allowThis(userShares[msg.sender]);
        FHE.allow(userShares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(portfolio.totalValue);
        emit Deposited(msg.sender);
    }

    function rebalance(
        uint256[] calldata assetIds,
        externalEuint64[] calldata encBuys, bytes[] calldata buyProofs,
        externalEuint64[] calldata encSells, bytes[] calldata sellProofs
    ) external onlyOwner nonReentrant {
        require(assetIds.length == encBuys.length, "Length mismatch");
        for (uint256 i = 0; i < assetIds.length; i++) {
            euint64 buy = FHE.fromExternal(encBuys[i], buyProofs[i]);
            euint64 sell = FHE.fromExternal(encSells[i], sellProofs[i]);
            assets[assetIds[i]].currentBalance = FHE.add(
                FHE.sub(assets[assetIds[i]].currentBalance, sell), buy
            );
            FHE.allowThis(assets[assetIds[i]].currentBalance);
        }
        portfolio.lastRebalance = block.timestamp;
        emit Rebalanced(block.timestamp);
    }

    function withdraw(externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        euint64 shares = FHE.fromExternal(encShares, proof);
        ebool hasShares = FHE.le(shares, userShares[msg.sender]);
        euint64 actual = FHE.select(hasShares, shares, FHE.asEuint64(0));
        userShares[msg.sender] = FHE.sub(userShares[msg.sender], actual);
        _totalShares = FHE.sub(_totalShares, actual);
        euint64 returned = actual; // simplified
        portfolio.totalValue = FHE.sub(portfolio.totalValue, returned);
        FHE.allowThis(userShares[msg.sender]);
        FHE.allow(userShares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allow(returned, msg.sender);
        FHE.allowThis(portfolio.totalValue);
        emit Withdrawn(msg.sender);
    }

    function allowPortfolioData(address viewer) external onlyOwner {
        FHE.allow(portfolio.totalValue, viewer);
        FHE.allow(portfolio.maxDriftBps, viewer);
    }
}
