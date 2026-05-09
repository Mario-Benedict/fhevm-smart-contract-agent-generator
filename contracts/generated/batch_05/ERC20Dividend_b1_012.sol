// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Dividend_b1_012 - Confidential ERC20 with dividend distribution
contract ERC20Dividend_b1_012 is ZamaEthereumConfig {
    string public name = "Dividend Token";
    string public symbol = "DIVT";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;
    euint64 private dividendPool;
    mapping(address => euint64) private claimedDividends;
    uint256 public totalDividendRounds;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(1_000_000);
        balances[msg.sender] = totalSupply;
        dividendPool = FHE.asEuint64(0);
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(dividendPool);
    }

    function depositDividend(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        dividendPool = FHE.add(dividendPool, amount);
        totalDividendRounds++;
        FHE.allowThis(dividendPool);
    }

    function claimDividend() public {
        // simplified proportional claim: balance / totalSupply * dividendPool
        euint64 myBalance = balances[msg.sender];
        euint64 claimed = claimedDividends[msg.sender];
        ebool hasBal = FHE.gt(myBalance, FHE.asEuint64(0));
        euint64 owed = FHE.select(hasBal, FHE.sub(dividendPool, claimed), FHE.asEuint64(0));
        claimedDividends[msg.sender] = FHE.add(claimed, owed);
        balances[msg.sender] = FHE.add(myBalance, owed);
        FHE.allowThis(claimedDividends[msg.sender]);
        FHE.allowThis(balances[msg.sender]);
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
