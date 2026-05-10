// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20BondingCurve_c2_004
/// @notice Token whose price follows an encrypted bonding curve:
///         price increases with supply. Buy/sell against a reserve.
contract ERC20BondingCurve_c2_004 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "BondCurve Token";
    string public symbol = "BCT";

    euint64 private _totalSupply;
    mapping(address => euint64) private _balances;
    euint64 private _reserveBalance; // ETH-like reserve (in wei-equivalent)
    uint32 public constant CURVE_SLOPE = 1000; // price = slope * supply

    event Buy(address indexed buyer);
    event Sell(address indexed seller);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _reserveBalance = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_reserveBalance);
    }

    /// @notice Calculate cost to buy `amount` tokens given current supply
    function _calculateBuyCost(euint64 amount) internal returns (euint64) {
        // cost = slope * (supply * amount + amount^2 / 2)
        euint64 supplyTimesAmount = FHE.mul(_totalSupply, amount); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 halfSquared = FHE.div(FHE.mul(amount, amount), 2);
        return FHE.mul(FHE.asEuint64(uint64(CURVE_SLOPE)), FHE.add(supplyTimesAmount, halfSquared));
    }

    function buy(externalEuint64 encAmount, bytes calldata proof, externalEuint64 encPayment, bytes calldata payProof)
        external nonReentrant
    {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 payment = FHE.fromExternal(encPayment, payProof);
        euint64 cost = _calculateBuyCost(amount);
        ebool sufficient = FHE.ge(payment, cost);
        euint64 actualAmount = FHE.select(sufficient, amount, FHE.asEuint64(0));
        euint64 actualCost = FHE.select(sufficient, cost, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.add(_balances[msg.sender], actualAmount);
        _totalSupply = FHE.add(_totalSupply, actualAmount);
        _reserveBalance = FHE.add(_reserveBalance, actualCost);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_reserveBalance);
        emit Buy(msg.sender);
    }

    function sell(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        euint64 actualAmount = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        // refund = slope * (supply * amount - amount^2 / 2)
        euint64 refund = FHE.mul(
            FHE.asEuint64(uint64(CURVE_SLOPE)),
            FHE.sub(
                FHE.mul(_totalSupply, actualAmount),
                FHE.div(FHE.mul(actualAmount, actualAmount), 2)
            )
        );
        ebool reserveOk = FHE.le(refund, _reserveBalance);
        euint64 actualRefund = FHE.select(reserveOk, refund, _reserveBalance);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualAmount);
        _totalSupply = FHE.sub(_totalSupply, actualAmount);
        _reserveBalance = FHE.sub(_reserveBalance, actualRefund);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_reserveBalance);
        FHE.allow(actualRefund, msg.sender);
        emit Sell(msg.sender);
    }

    function allowReserve(address viewer) external onlyOwner {
        FHE.allow(_reserveBalance, viewer);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
