// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title DeFiPrivateVault
/// @notice Multistrategy vault with encrypted performance fees. The vault manager
///         allocates capital across strategies with private allocation amounts.
///         Users see only their own encrypted share balance.
contract DeFiPrivateVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct VaultUser {
        euint64 shares;
        euint64 depositedValue;
        uint256 depositTime;
        bool enrolled;
    }

    euint64 private _totalAssets;
    euint64 private _totalShares;
    euint64 private _performanceFeeBps;
    euint64 private _managementFeeBps;
    euint64 private _accruedFees;
    mapping(address => VaultUser) private users;
    address[] public userList;

    event Deposited(address indexed user);
    event Withdrawn(address indexed user);
    event FeesCollected();
    event YieldAccrued();

    constructor(
        externalEuint64 encPerfFee, bytes memory pfProof,
        externalEuint64 encMgmtFee, bytes memory mfProof
    ) Ownable(msg.sender) {
        _performanceFeeBps = FHE.fromExternal(encPerfFee, pfProof);
        _managementFeeBps = FHE.fromExternal(encMgmtFee, mfProof);
        _totalAssets = FHE.asEuint64(0);
        _totalShares = FHE.asEuint64(0);
        _accruedFees = FHE.asEuint64(0);
        FHE.allowThis(_performanceFeeBps);
        FHE.allowThis(_managementFeeBps);
        FHE.allowThis(_totalAssets);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_accruedFees);
    }

    function deposit(externalEuint64 encAmount, bytes calldata proof) external nonReentrant whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (!users[msg.sender].enrolled) {
            users[msg.sender].enrolled = true;
            users[msg.sender].shares = FHE.asEuint64(0);
            users[msg.sender].depositedValue = FHE.asEuint64(0);
            FHE.allowThis(users[msg.sender].shares);
            FHE.allowThis(users[msg.sender].depositedValue);
            userList.push(msg.sender);
        }
        euint64 newShares = amount; // 1:1 initially
        users[msg.sender].shares = FHE.add(users[msg.sender].shares, newShares);
        users[msg.sender].depositedValue = FHE.add(users[msg.sender].depositedValue, amount);
        users[msg.sender].depositTime = block.timestamp;
        _totalAssets = FHE.add(_totalAssets, amount);
        _totalShares = FHE.add(_totalShares, newShares);
        FHE.allow(users[msg.sender].shares, msg.sender);
        FHE.allow(users[msg.sender].depositedValue, msg.sender);
        FHE.allowThis(_totalAssets);
        FHE.allowThis(_totalShares);
        emit Deposited(msg.sender);
    }

    function recordYield(externalEuint64 encYield, bytes calldata proof) external onlyOwner {
        euint64 yield = FHE.fromExternal(encYield, proof);
        euint64 perfFee = FHE.div(FHE.mul(yield, _performanceFeeBps), 10000);
        ebool _safeSub136 = FHE.ge(yield, perfFee);
        euint64 netYield = FHE.select(_safeSub136, FHE.sub(yield, perfFee), FHE.asEuint64(0));
        _accruedFees = FHE.add(_accruedFees, perfFee);
        _totalAssets = FHE.add(_totalAssets, netYield);
        FHE.allowThis(_accruedFees);
        FHE.allowThis(_totalAssets);
        emit YieldAccrued();
    }

    function collectFees() external onlyOwner {
        FHE.allow(_accruedFees, owner());
        _accruedFees = FHE.asEuint64(0);
        FHE.allowThis(_accruedFees);
        emit FeesCollected();
    }

    function withdraw(externalEuint64 encShares, bytes calldata proof) external nonReentrant whenNotPaused {
        euint64 shares = FHE.fromExternal(encShares, proof);
        VaultUser storage u = users[msg.sender];
        require(u.enrolled, "Not enrolled");
        ebool hasShares = FHE.le(shares, u.shares);
        euint64 actual = FHE.select(hasShares, shares, FHE.asEuint64(0));
        ebool _safeSub137 = FHE.ge(u.shares, actual);
        u.shares = FHE.select(_safeSub137, FHE.sub(u.shares, actual), FHE.asEuint64(0));
        euint64 returned = actual; // simplified
        ebool _safeSub138 = FHE.ge(_totalShares, actual);
        _totalShares = FHE.select(_safeSub138, FHE.sub(_totalShares, actual), FHE.asEuint64(0));
        ebool _safeSub139 = FHE.ge(_totalAssets, returned);
        _totalAssets = FHE.select(_safeSub139, FHE.sub(_totalAssets, returned), FHE.asEuint64(0));
        FHE.allowThis(u.shares);
        FHE.allow(u.shares, msg.sender);
        FHE.allow(returned, msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAssets);
        emit Withdrawn(msg.sender);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowUserData(address viewer) external {
        FHE.allow(users[msg.sender].shares, viewer);
        FHE.allow(users[msg.sender].depositedValue, viewer);
    }

    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalAssets, viewer);
        FHE.allow(_totalShares, viewer);
        FHE.allow(_accruedFees, viewer);
    }
}
