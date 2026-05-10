// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20FeeOnTransfer_b1_009 - ERC20 with confidential fee-on-transfer
contract ERC20FeeOnTransfer_b1_009 is ZamaEthereumConfig {
    string public name = "Fee Token";
    string public symbol = "FETK";
    uint8 public decimals = 18;

    address public owner;
    address public feeCollector;
    uint8 public feePercent; // plaintext fee %
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _feeCollector, uint8 _feePercent) {
        require(_feePercent <= 10, "Max 10% fee");
        owner = msg.sender;
        feeCollector = _feeCollector;
        feePercent = _feePercent;
        totalSupply = FHE.asEuint64(1_000_000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));

        // fee = actual * feePercent / 100
        euint64 fee = FHE.mul(actual, FHE.asEuint64(uint64(feePercent))); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 net = FHE.sub(actual, fee);

        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], net);
        balances[feeCollector] = FHE.add(balances[feeCollector], fee);

        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
        FHE.allowThis(balances[feeCollector]);
    }

    function setFeeCollector(address newCollector) public onlyOwner {
        feeCollector = newCollector;
    }

    function setFeePercent(uint8 _fee) public onlyOwner {
        require(_fee <= 10, "Max 10%");
        feePercent = _fee;
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
