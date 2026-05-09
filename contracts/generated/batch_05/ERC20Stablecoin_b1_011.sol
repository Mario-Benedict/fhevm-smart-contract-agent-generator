// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Stablecoin_b1_011 - Confidential stablecoin with collateral tracking
contract ERC20Stablecoin_b1_011 is ZamaEthereumConfig {
    string public name = "Private Stablecoin";
    string public symbol = "PUSD";
    uint8 public decimals = 6;

    address public owner;
    euint32 private totalSupply;
    mapping(address => euint32) private balances;
    mapping(address => euint32) private collateral;

    uint8 public constant MIN_COLLATERAL_RATIO = 150; // 150%

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint32(0);
        FHE.allowThis(totalSupply);
    }

    function depositCollateralAndMint(
        externalEuint32 collateralStr,
        bytes calldata proof
    ) public {
        euint32 col = FHE.fromExternal(collateralStr, proof);
        collateral[msg.sender] = FHE.add(collateral[msg.sender], col);
        FHE.allowThis(collateral[msg.sender]);

        // mint = collateral * 100 / 150
        euint32 mintAmount = FHE.mul(col, FHE.asEuint32(66));
        balances[msg.sender] = FHE.add(balances[msg.sender], mintAmount);
        totalSupply = FHE.add(totalSupply, mintAmount);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
    }

    function repayAndWithdraw(externalEuint32 repayStr, bytes calldata proof) public {
        euint32 repay = FHE.fromExternal(repayStr, proof);
        ebool ok = FHE.le(repay, balances[msg.sender]);
        euint32 actual = FHE.select(ok, repay, FHE.asEuint32(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        totalSupply = FHE.sub(totalSupply, actual);

        // Return collateral = repay * 150 / 100
        euint32 collateralReturn = FHE.mul(actual, FHE.asEuint32(150));
        ebool hasSufficientCol = FHE.ge(collateral[msg.sender], collateralReturn);
        euint32 actualReturn = FHE.select(hasSufficientCol, collateralReturn, collateral[msg.sender]);
        collateral[msg.sender] = FHE.sub(collateral[msg.sender], actualReturn);

        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(totalSupply);
        FHE.allowThis(collateral[msg.sender]);
    }

    function transfer(address to, externalEuint32 amountStr, bytes calldata proof) public {
        euint32 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint32 actual = FHE.select(ok, amount, FHE.asEuint32(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
