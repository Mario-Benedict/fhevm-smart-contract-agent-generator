// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OnyxInstitutionalToken
/// @notice Confidential institutional token with compliance checks and transfer limits
contract OnyxInstitutionalToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Onyx Institutional";
    string public constant symbol = "ONYX";

    mapping(address => euint64) private _balances;
    mapping(address => bool) public kycApproved;
    mapping(address => euint64) private _dailyTransferred;
    mapping(address => uint256) public lastTransferDay;

    euint64 public dailyTransferLimit;

    event KYCApproved(address indexed account);
    event KYCRevoked(address indexed account);

    constructor() Ownable(msg.sender) {
        dailyTransferLimit = FHE.asEuint64(1_000_000);
        FHE.allowThis(dailyTransferLimit);
        kycApproved[msg.sender] = true;
    }

    modifier onlyKYC(address account) {
        require(kycApproved[account], "KYC not approved");
        _;
    }

    function approveKYC(address account) external onlyOwner {
        kycApproved[account] = true;
        emit KYCApproved(account);
    }

    function revokeKYC(address account) external onlyOwner {
        kycApproved[account] = false;
        emit KYCRevoked(account);
    }

    function mint(address to, externalEuint64 calldata encAmount, bytes calldata proof) external onlyOwner onlyKYC(to) {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function _resetDailyIfNeeded(address account) internal {
        uint256 today = block.timestamp / 1 days;
        if (lastTransferDay[account] < today) {
            _dailyTransferred[account] = FHE.asEuint64(0);
            FHE.allowThis(_dailyTransferred[account]);
            lastTransferDay[account] = today;
        }
    }

    function transfer(
        address to,
        externalEuint64 calldata encAmount,
        bytes calldata proof
    ) external onlyKYC(msg.sender) onlyKYC(to) nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _resetDailyIfNeeded(msg.sender);

        euint64 newDailyTotal = FHE.add(_dailyTransferred[msg.sender], amount);
        ebool withinLimit = FHE.le(newDailyTotal, dailyTransferLimit);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        ebool canTransfer = FHE.and(withinLimit, hasFunds);

        euint64 actualAmount = FHE.select(canTransfer, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualAmount);
        _balances[to] = FHE.add(_balances[to], actualAmount);
        _dailyTransferred[msg.sender] = FHE.add(_dailyTransferred[msg.sender], actualAmount);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_dailyTransferred[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
    }

    function setDailyLimit(externalEuint64 calldata encLimit, bytes calldata proof) external onlyOwner {
        dailyTransferLimit = FHE.fromExternal(encLimit, proof);
        FHE.allowThis(dailyTransferLimit);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
