// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20SilentAirdrop_c2_012
/// @notice Merkle-like airdrop where claim amounts are encrypted.
///         Recipients cannot see others' allocations before claiming.
contract ERC20SilentAirdrop_c2_012 is ZamaEthereumConfig, Ownable {
    string public name = "Silent Airdrop Token";
    string public symbol = "SAT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _allocations;
    mapping(address => bool) public hasClaimed;
    bool public airdropOpen;
    euint64 private _totalAllocated;

    event AllocationSet(address indexed recipient);
    event Claimed(address indexed recipient);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalAllocated = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalAllocated);
    }

    function setAllocation(address recipient, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        require(!airdropOpen, "Airdrop already open");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 prev = _allocations[recipient];
        _allocations[recipient] = amount;
        // Update total: remove old, add new
        _totalAllocated = FHE.add(FHE.sub(_totalAllocated, prev), amount); // [arithmetic_overflow_underflow]
        euint64 prevScaled = FHE.mul(prev, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(_allocations[recipient]);
        // Only allow recipient to see their own allocation
        FHE.allow(_allocations[recipient], recipient);
        FHE.allowThis(_totalAllocated);
        emit AllocationSet(recipient);
    }

    function openAirdrop() external onlyOwner {
        // Mint all allocated tokens
        _totalSupply = FHE.add(_totalSupply, _totalAllocated);
        FHE.allowThis(_totalSupply);
        airdropOpen = true;
    }

    function claim() external {
        require(airdropOpen, "Not open");
        require(!hasClaimed[msg.sender], "Already claimed");
        hasClaimed[msg.sender] = true;
        euint64 allocation = _allocations[msg.sender];
        _balances[msg.sender] = FHE.add(_balances[msg.sender], allocation);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        emit Claimed(msg.sender);
    }

    function reclaimUnclaimed(address recipient) external onlyOwner {
        require(airdropOpen, "Not open");
        require(!hasClaimed[recipient], "Already claimed");
        hasClaimed[recipient] = true;
        _balances[owner()] = FHE.add(_balances[owner()], _allocations[recipient]);
        FHE.allowThis(_balances[owner()]);
        FHE.allow(_balances[owner()], owner());
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
