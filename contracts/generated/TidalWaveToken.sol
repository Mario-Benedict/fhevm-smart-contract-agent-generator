// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title TidalWaveToken - Confidential ERC20 with per-account daily transfer limits
contract TidalWaveToken is ZamaEthereumConfig, Ownable {
    string public constant name = "TidalWave";
    string public constant symbol = "TWV";

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _dailyTransferred;
    mapping(address => uint256) private _lastTransferDay;
    euint64 public dailyLimit;

    event Transfer(address indexed from, address indexed to);

    constructor(externalEuint64 calldata encLimit, bytes calldata inputProof) Ownable(msg.sender) {
        dailyLimit = FHE.fromExternal(encLimit, inputProof);
        FHE.allowThis(dailyLimit);
    }

    function _resetDailyIfNeeded(address account) internal {
        uint256 today = block.timestamp / 1 days;
        if (_lastTransferDay[account] < today) {
            _dailyTransferred[account] = FHE.asEuint64(0);
            FHE.allowThis(_dailyTransferred[account]);
            _lastTransferDay[account] = today;
        }
    }

    function mint(address to, externalEuint64 calldata encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function transfer(address to, externalEuint64 calldata encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _resetDailyIfNeeded(msg.sender);

        euint64 newDailyTotal = FHE.add(_dailyTransferred[msg.sender], amount);
        ebool withinLimit = FHE.le(newDailyTotal, dailyLimit);
        euint64 safeAmount = FHE.select(withinLimit, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], safeAmount);
        _balances[to] = FHE.add(_balances[to], safeAmount);
        _dailyTransferred[msg.sender] = FHE.add(_dailyTransferred[msg.sender], safeAmount);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allowThis(_dailyTransferred[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    function setDailyLimit(externalEuint64 calldata encLimit, bytes calldata inputProof) external onlyOwner {
        dailyLimit = FHE.fromExternal(encLimit, inputProof);
        FHE.allowThis(dailyLimit);
    }
}
