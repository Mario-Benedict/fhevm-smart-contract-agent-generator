// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateDerivativesSettlement
/// @notice OTC derivatives with encrypted strike prices and notional amounts.
///         Settlement computed privately; only P&L revealed to counterparties.
contract PrivateDerivativesSettlement is ZamaEthereumConfig, Ownable {
    enum DerivativeType { Forward, Option, Swap }
    enum OptionType { Call, Put }

    struct Derivative {
        address buyer;
        address seller;
        DerivativeType dType;
        OptionType oType;
        euint64 notionalAmount;
        euint64 strikePrice;
        euint64 premium;
        uint256 expiryDate;
        bool settled;
        bool exercised;
    }

    mapping(uint256 => Derivative) private derivatives;
    mapping(address => euint64) private _margin;
    mapping(address => euint64) private _pnl;
    uint256 public nextDerivativeId;
    address public priceOracle;

    event DerivativeCreated(uint256 indexed id, address buyer, address seller);
    event DerivativeSettled(uint256 indexed id);

    modifier onlyOracle() {
        require(msg.sender == priceOracle || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor(address oracle) Ownable(msg.sender) {
        priceOracle = oracle;
    }

    function depositMargin(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _margin[msg.sender] = FHE.add(_margin[msg.sender], amount);
        FHE.allowThis(_margin[msg.sender]);
        FHE.allow(_margin[msg.sender], msg.sender);
    }

    function createDerivative(
        address seller,
        DerivativeType dType,
        OptionType oType,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encPremium, bytes calldata pProof,
        uint256 expiryDays
    ) external returns (uint256 id) {
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        // Lock premium from buyer's margin
        ebool hasPremium = FHE.ge(_margin[msg.sender], premium);
        euint64 lockedPremium = FHE.select(hasPremium, premium, FHE.asEuint64(0));
        _margin[msg.sender] = FHE.sub(_margin[msg.sender], lockedPremium);
        _margin[seller] = FHE.add(_margin[seller], lockedPremium);
        FHE.allowThis(_margin[msg.sender]);
        FHE.allowThis(_margin[seller]);

        id = nextDerivativeId++;
        derivatives[id] = Derivative({
            buyer: msg.sender, seller: seller,
            dType: dType, oType: oType,
            notionalAmount: notional, strikePrice: strike, premium: premium,
            expiryDate: block.timestamp + expiryDays * 1 days,
            settled: false, exercised: false
        });
        FHE.allowThis(derivatives[id].notionalAmount);
        FHE.allow(derivatives[id].notionalAmount, seller);
        FHE.allowThis(derivatives[id].strikePrice);
        FHE.allow(derivatives[id].strikePrice, seller);
        FHE.allowThis(derivatives[id].premium);
        emit DerivativeCreated(id, msg.sender, seller);
    }

    function settle(uint256 derivativeId, externalEuint64 encSpotPrice, bytes calldata proof) external onlyOracle {
        Derivative storage d = derivatives[derivativeId];
        require(!d.settled && block.timestamp >= d.expiryDate, "Not expired");
        d.settled = true;
        euint64 spotPrice = FHE.fromExternal(encSpotPrice, proof);

        // P&L for call option: max(spot - strike, 0) * notional
        ebool inTheMoney = FHE.gt(spotPrice, d.strikePrice);
        euint64 priceDiff = FHE.select(inTheMoney, FHE.sub(spotPrice, d.strikePrice), FHE.asEuint64(0));
        euint64 payoff = FHE.div(FHE.mul(priceDiff, d.notionalAmount), 1000); // scale

        if (d.oType == OptionType.Put) {
            ebool putITM = FHE.gt(d.strikePrice, spotPrice);
            euint64 putDiff = FHE.select(putITM, FHE.sub(d.strikePrice, spotPrice), FHE.asEuint64(0));
            payoff = FHE.div(FHE.mul(putDiff, d.notionalAmount), 1000);
        }

        _pnl[d.buyer] = FHE.add(_pnl[d.buyer], payoff);
        FHE.allowThis(_pnl[d.buyer]);
        FHE.allow(_pnl[d.buyer], d.buyer);
        emit DerivativeSettled(derivativeId);
    }

    function withdrawPnl() external {
        euint64 pnl = _pnl[msg.sender];
        _pnl[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_pnl[msg.sender]);
        FHE.allow(pnl, msg.sender);
    }

    function allowDerivativeDetails(uint256 id, address viewer) external {
        Derivative storage d = derivatives[id];
        require(msg.sender == d.buyer || msg.sender == d.seller || msg.sender == owner(), "Unauthorized");
        FHE.allow(d.notionalAmount, viewer);
        FHE.allow(d.strikePrice, viewer);
    }
}
