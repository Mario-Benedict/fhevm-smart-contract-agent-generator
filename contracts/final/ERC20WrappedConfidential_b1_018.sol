// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20WrappedConfidential_b1_018 - Wrap ETH into confidential token
contract ERC20WrappedConfidential_b1_018 is ZamaEthereumConfig {
    string public name = "Wrapped Confidential ETH";
    string public symbol = "WCETH";
    uint8 public decimals = 18;

    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user);

    constructor() {
        totalSupply = FHE.asEuint64(0);
        FHE.allowThis(totalSupply);
    }

    function deposit() public payable {
        require(msg.value > 0, "No ETH sent");
        uint64 amount = uint64(msg.value / 1 gwei);
        balances[msg.sender] = FHE.add(balances[msg.sender], FHE.asEuint64(uint64(amount)));
        totalSupply = FHE.add(totalSupply, FHE.asEuint64(uint64(amount)));
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        totalSupply = FHE.sub(totalSupply, actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
        emit Withdrawn(msg.sender);
        // Note: actual ETH withdrawal would require decryption callback
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
