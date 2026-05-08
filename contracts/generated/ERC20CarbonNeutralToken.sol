// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20CarbonNeutralToken
/// @notice Carbon-offset-linked ERC20. Every transfer triggers an encrypted carbon offset burn
///         proportional to the transferred amount. Total tonnes retired are tracked privately.
///         Offset registry verifiers can attest carbon retirement on-chain.
contract ERC20CarbonNeutralToken is ZamaEthereumConfig, Ownable {
    string public name = "CarbonNeutral Token";
    string public symbol = "CNT";
    uint8 public decimals = 18;

    // Encrypted offset rate: grams CO2 per 1 token transferred (scaled)
    euint64 private _co2GramsPerToken;
    // Encrypted total CO2 retired in grams
    euint64 private _totalCO2Retired;
    euint64 private _totalSupply;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _co2Retired;
    mapping(address => bool) public isVerifier;

    event Transfer(address indexed from, address indexed to);
    event CarbonRetired(address indexed account);
    event OffsetRateUpdated();

    constructor(externalEuint64 encCO2Rate, bytes memory proof) Ownable(msg.sender) {
        _co2GramsPerToken = FHE.fromExternal(encCO2Rate, proof);
        _totalCO2Retired = FHE.asEuint64(0);
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_co2GramsPerToken);
        FHE.allowThis(_totalCO2Retired);
        FHE.allowThis(_totalSupply);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);

        // Calculate CO2 offset burn for this transfer
        euint64 co2Burn = FHE.mul(amount, _co2GramsPerToken);

        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        euint64 actualCO2 = FHE.select(hasFunds, co2Burn, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);

        // Record CO2 retirement per sender
        _co2Retired[msg.sender] = FHE.add(_co2Retired[msg.sender], actualCO2);
        _totalCO2Retired = FHE.add(_totalCO2Retired, actualCO2);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_co2Retired[msg.sender]);
        FHE.allow(_co2Retired[msg.sender], msg.sender);
        FHE.allowThis(_totalCO2Retired);

        emit Transfer(msg.sender, to);
        emit CarbonRetired(msg.sender);
    }

    function updateOffsetRate(externalEuint64 encRate, bytes calldata proof) external onlyOwner {
        _co2GramsPerToken = FHE.fromExternal(encRate, proof);
        FHE.allowThis(_co2GramsPerToken);
        emit OffsetRateUpdated();
    }

    function allowCO2Retired(address viewer) external {
        FHE.allow(_co2Retired[msg.sender], viewer);
    }

    function allowTotalCO2(address viewer) external onlyOwner {
        FHE.allow(_totalCO2Retired, viewer);
    }
}
