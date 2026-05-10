// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingMultiAsset_b4_008 - Multi-asset confidential lending protocol
contract LendingMultiAsset_b4_008 is ZamaEthereumConfig {
    address public admin;

    struct Asset {
        string symbol;
        uint8 collateralFactor; // e.g. 75 means 75% LTV
        euint64 totalDeposited;
        euint64 totalBorrowed;
    }

    Asset[] public assets;
    mapping(address => mapping(uint256 => euint64)) private userDeposits;
    mapping(address => mapping(uint256 => euint64)) private userBorrows;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function addAsset(string calldata symbol, uint8 collateralFactor) public onlyAdmin returns (uint256) {
        uint256 id = assets.length;
        assets.push(Asset({
            symbol: symbol,
            collateralFactor: collateralFactor,
            totalDeposited: FHE.asEuint64(0),
            totalBorrowed: FHE.asEuint64(0)
        }));
        FHE.allowThis(assets[id].totalDeposited);
        FHE.allowThis(assets[id].totalBorrowed);
        return id;
    }

    function deposit(uint256 assetId, externalEuint64 amountStr, bytes calldata proof) public {
        require(assetId < assets.length, "Invalid asset");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        userDeposits[msg.sender][assetId] = FHE.add(userDeposits[msg.sender][assetId], amount);
        assets[assetId].totalDeposited = FHE.add(assets[assetId].totalDeposited, amount);
        FHE.allowThis(userDeposits[msg.sender][assetId]);
        FHE.allowThis(assets[assetId].totalDeposited);
    }

    function borrow(uint256 assetId, externalEuint64 amountStr, bytes calldata proof) public {
        require(assetId < assets.length, "Invalid asset");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        euint64 available = FHE.sub(assets[assetId].totalDeposited, assets[assetId].totalBorrowed); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        ebool ok = FHE.le(amount, available);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        userBorrows[msg.sender][assetId] = FHE.add(userBorrows[msg.sender][assetId], actual);
        assets[assetId].totalBorrowed = FHE.add(assets[assetId].totalBorrowed, actual);
        FHE.allowThis(userBorrows[msg.sender][assetId]);
        FHE.allowThis(assets[assetId].totalBorrowed);
    }

    function allowUserDeposit(uint256 assetId, address viewer) public {
        FHE.allow(userDeposits[msg.sender][assetId], viewer);
    }

    function allowUserBorrow(uint256 assetId, address viewer) public {
        FHE.allow(userBorrows[msg.sender][assetId], viewer);
    }

    function getAssetCount() public view returns (uint256) {
        return assets.length;
    }
}
