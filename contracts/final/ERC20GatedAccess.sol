// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ERC20GatedAccess
/// @notice KYC-gated confidential token. Users must pass encrypted KYC verification before
///         transferring. Per-wallet encrypted transfer caps prevent whale concentration.
contract ERC20GatedAccess is ZamaEthereumConfig, Ownable, Pausable {
    string public name = "Gated Access Token";
    string public symbol = "GAT";
    uint8 public decimals = 18;

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _transferCap;
    mapping(address => euint64) private _transferredToday;
    mapping(address => uint256) private _lastTransferDay;
    mapping(address => bool) public kycApproved;
    mapping(address => bool) public isKYCAuthority;

    event Mint(address indexed to);
    event TransferCapped(address indexed from, address indexed to);
    event KYCApproved(address indexed user);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        isKYCAuthority[msg.sender] = true;
    }

    function addKYCAuthority(address auth) external onlyOwner { isKYCAuthority[auth] = true; }

    function approveKYC(address user) external {
        require(isKYCAuthority[msg.sender], "Not authority");
        kycApproved[user] = true;
        emit KYCApproved(user);
    }

    function revokeKYC(address user) external {
        require(isKYCAuthority[msg.sender], "Not authority");
        kycApproved[user] = false;
    }

    function setTransferCap(address user, externalEuint64 encCap, bytes calldata proof) external onlyOwner {
        _transferCap[user] = FHE.fromExternal(encCap, proof);
        FHE.allowThis(_transferCap[user]);
        FHE.allow(_transferCap[user], user);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        require(kycApproved[to], "KYC required");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Mint(to);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        require(kycApproved[msg.sender] && kycApproved[to], "KYC required");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (block.timestamp / 1 days > _lastTransferDay[msg.sender]) {
            _transferredToday[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_transferredToday[msg.sender]);
            _lastTransferDay[msg.sender] = block.timestamp / 1 days;
        }
        euint64 newTransferred = FHE.add(_transferredToday[msg.sender], amount);
        ebool withinCap = FHE.le(newTransferred, _transferCap[msg.sender]);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        ebool canTransfer = FHE.and(withinCap, hasFunds);
        euint64 actual = FHE.select(canTransfer, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _balances[to] = FHE.add(_balances[to], actual);
        _transferredToday[msg.sender] = FHE.add(_transferredToday[msg.sender], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_transferredToday[msg.sender]);
        emit TransferCapped(msg.sender, to);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function allowBalance(address viewer) external { FHE.allow(_balances[msg.sender], viewer); }
}
