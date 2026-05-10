// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Governance_b1_017 - Confidential ERC20 with on-chain governance weight
contract ERC20Governance_b1_017 is ZamaEthereumConfig {
    string public name = "Governance Token";
    string public symbol = "GOV";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;
    mapping(address => address) public delegates;
    mapping(address => euint64) private votingPower;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(100_000_000);
        balances[msg.sender] = totalSupply;
        votingPower[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(votingPower[msg.sender]);
    }

    function delegate(address to) public {
        address oldDelegate = delegates[msg.sender];
        if (oldDelegate != address(0)) {
            votingPower[oldDelegate] = FHE.sub(votingPower[oldDelegate], balances[msg.sender]); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(votingPower[oldDelegate]);
        }
        delegates[msg.sender] = to;
        votingPower[to] = FHE.add(votingPower[to], balances[msg.sender]);
        FHE.allowThis(votingPower[to]);
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);

        // Update voting power for delegates
        address fromDelegate = delegates[msg.sender];
        address toDelegate = delegates[to];
        if (fromDelegate != address(0)) {
            votingPower[fromDelegate] = FHE.sub(votingPower[fromDelegate], actual);
            FHE.allowThis(votingPower[fromDelegate]);
        }
        if (toDelegate != address(0)) {
            votingPower[toDelegate] = FHE.add(votingPower[toDelegate], actual);
            FHE.allowThis(votingPower[toDelegate]);
        }

        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowVotingPower(address viewer) public {
        FHE.allow(votingPower[msg.sender], viewer);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
