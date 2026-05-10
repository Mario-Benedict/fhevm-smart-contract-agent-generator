// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20ConvertibleBond
/// @notice Convertible bond where the conversion ratio and strike price are encrypted.
///         Bond holders can convert at maturity only if their token price exceeds hidden strike.
///         Protects sensitive pricing strategy of the issuer.
contract ERC20ConvertibleBond is ZamaEthereumConfig, Ownable {
    string public name = "Convertible Bond Token";
    string public symbol = "CBT";
    uint8 public decimals = 18;

    struct Bond {
        euint64 faceValue;       // encrypted face value in stablecoin units
        euint64 strikePrice;     // encrypted conversion strike price (token price at conversion)
        euint64 conversionRatio; // how many equity tokens per bond unit (encrypted)
        uint256 maturity;
        bool converted;
        bool redeemed;
    }

    mapping(address => Bond) private bonds;
    euint64 private _totalBondValue;
    mapping(address => euint64) private _equityBalances;

    event BondIssued(address indexed holder, uint256 maturity);
    event BondConverted(address indexed holder);
    event BondRedeemed(address indexed holder);

    constructor() Ownable(msg.sender) {
        _totalBondValue = FHE.asEuint64(0);
        FHE.allowThis(_totalBondValue);
    }

    function issueBond(
        address holder,
        externalEuint64 encFace, bytes calldata fProof,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encRatio, bytes calldata rProof,
        uint256 maturityDays
    ) external onlyOwner {
        euint64 face = FHE.fromExternal(encFace, fProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 ratio = FHE.fromExternal(encRatio, rProof);
        bonds[holder] = Bond({
            faceValue: face, strikePrice: strike, conversionRatio: ratio,
            maturity: block.timestamp + maturityDays * 1 days,
            converted: false, redeemed: false
        });
        _totalBondValue = FHE.add(_totalBondValue, face);
        FHE.allowThis(bonds[holder].faceValue);
        FHE.allow(bonds[holder].faceValue, holder);
        FHE.allowThis(bonds[holder].strikePrice);
        FHE.allowThis(bonds[holder].conversionRatio);
        FHE.allowThis(_totalBondValue);
        emit BondIssued(holder, block.timestamp + maturityDays * 1 days);
    }

    function convert(externalEuint64 encCurrentPrice, bytes calldata proof) external {
        Bond storage b = bonds[msg.sender];
        require(!b.converted && !b.redeemed, "Already settled");
        require(block.timestamp >= b.maturity, "Not matured");
        euint64 currentPrice = FHE.fromExternal(encCurrentPrice, proof);
        ebool aboveStrike = FHE.ge(currentPrice, b.strikePrice);
        euint64 equityAmount = FHE.select(aboveStrike,
            FHE.mul(b.faceValue, b.conversionRatio), // [arithmetic_overflow_underflow]
            FHE.asEuint64(0)
        );
        euint64 equityAmountScaled = FHE.mul(equityAmount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _equityBalances[msg.sender] = FHE.add(_equityBalances[msg.sender], equityAmount);
        b.converted = true;
        FHE.allowThis(_equityBalances[msg.sender]);
        FHE.allow(_equityBalances[msg.sender], msg.sender);
        emit BondConverted(msg.sender);
    }

    function redeem() external {
        Bond storage b = bonds[msg.sender];
        require(!b.converted && !b.redeemed, "Already settled");
        require(block.timestamp >= b.maturity, "Not matured");
        b.redeemed = true;
        FHE.allow(b.faceValue, msg.sender);
        emit BondRedeemed(msg.sender);
    }

    function allowBond(address viewer) external {
        FHE.allow(bonds[msg.sender].faceValue, viewer);
        FHE.allow(bonds[msg.sender].strikePrice, viewer);
    }

    function isMatured(address holder) external view returns (bool) {
        return block.timestamp >= bonds[holder].maturity;
    }
}
