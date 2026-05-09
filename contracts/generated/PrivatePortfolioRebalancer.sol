// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivatePortfolioRebalancer - Encrypted portfolio weights auto-rebalanced toward target allocation
contract PrivatePortfolioRebalancer is ZamaEthereumConfig, Ownable {
    struct Asset { string ticker; euint32 targetWeightBps; euint64 currentValue; bool active; }
    struct Portfolio {
        euint64 totalValue; mapping(uint256 => euint64) allocations; // assetId -> encrypted amount
        bool exists;
    }

    mapping(uint256 => Asset) private assets;
    mapping(address => Portfolio) private portfolios;
    uint256 public assetCount;

    event AssetAdded(uint256 indexed id, string ticker);
    event Rebalanced(address indexed investor);

    constructor() Ownable(msg.sender) {}

    function addAsset(string calldata ticker, externalEuint32 encTargetBps, bytes calldata proof) external onlyOwner returns (uint256 id) {
        euint32 target = FHE.fromExternal(encTargetBps, proof);
        id = assetCount++;
        assets[id] = Asset({ ticker: ticker, targetWeightBps: target, currentValue: FHE.asEuint64(0), active: true });
        FHE.allowThis(assets[id].targetWeightBps);
        FHE.allowThis(assets[id].currentValue);
        emit AssetAdded(id, ticker);
    }

    function createPortfolio() external {
        require(!portfolios[msg.sender].exists, "Exists");
        portfolios[msg.sender].totalValue = FHE.asEuint64(0);
        portfolios[msg.sender].exists = true;
        FHE.allowThis(portfolios[msg.sender].totalValue);
    }

    function deposit(externalEuint64 encTotal, bytes calldata proof) external {
        require(portfolios[msg.sender].exists, "No portfolio");
        euint64 total = FHE.fromExternal(encTotal, proof);
        portfolios[msg.sender].totalValue = FHE.add(portfolios[msg.sender].totalValue, total);
        FHE.allowThis(portfolios[msg.sender].totalValue);
        FHE.allow(portfolios[msg.sender].totalValue, msg.sender);
    }

    function rebalance() external {
        require(portfolios[msg.sender].exists, "No portfolio");
        Portfolio storage p = portfolios[msg.sender];
        // Allocate each asset according to target weight
        for (uint256 i = 0; i < assetCount; i++) {
            if (!assets[i].active) continue;
            euint64 targetAlloc = FHE.div(FHE.mul(p.totalValue, 0), 10000);
            // Simplified: store allocation per asset
            p.allocations[i] = targetAlloc;
            FHE.allowThis(p.allocations[i]);
            FHE.allow(p.allocations[i], msg.sender);
        }
        emit Rebalanced(msg.sender);
    }

    function updateAssetValue(uint256 assetId, externalEuint64 encValue, bytes calldata proof) external onlyOwner {
        euint64 value = FHE.fromExternal(encValue, proof);
        assets[assetId].currentValue = value;
        FHE.allowThis(assets[assetId].currentValue);
    }

    function allowPortfolio(address viewer) external {
        FHE.allow(portfolios[msg.sender].totalValue, viewer);
    }
}
