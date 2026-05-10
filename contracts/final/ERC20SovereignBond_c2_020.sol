// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20SovereignBond_c2_020
/// @notice Government bond token: bonds are issued with encrypted face value
///         and coupon payments. Investors buy at discount, receive coupons, redeem at maturity.
contract ERC20SovereignBond_c2_020 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Sovereign Bond Token";
    string public symbol = "SBT";

    struct Bond {
        address issuer;
        address holder;
        euint64 faceValue;
        euint64 couponRate;    // encrypted bps per year
        euint64 purchasePrice; // encrypted
        uint256 maturityDate;
        uint256 lastCouponDate;
        bool redeemed;
    }

    mapping(uint256 => Bond) private bonds;
    uint256 public nextBondId;
    mapping(address => euint64) private _reserves; // issuer reserves
    euint64 private _totalIssued;

    event BondIssued(uint256 indexed bondId, address indexed holder);
    event CouponPaid(uint256 indexed bondId);
    event BondRedeemed(uint256 indexed bondId);

    constructor() Ownable(msg.sender) {
        _totalIssued = FHE.asEuint64(0);
        FHE.allowThis(_totalIssued);
    }

    function depositReserves(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _reserves[msg.sender] = FHE.add(_reserves[msg.sender], amount);
        FHE.allowThis(_reserves[msg.sender]);
        FHE.allow(_reserves[msg.sender], msg.sender);
    }

    function issueBond(
        address holder,
        externalEuint64 encFaceValue, bytes calldata faceProof,
        externalEuint64 encCoupon, bytes calldata couponProof,
        externalEuint64 encPurchasePrice, bytes calldata priceProof,
        uint256 maturityYears
    ) external nonReentrant returns (uint256 bondId) {
        euint64 faceValue = FHE.fromExternal(encFaceValue, faceProof);
        euint64 coupon = FHE.fromExternal(encCoupon, couponProof);
        euint64 purchasePrice = FHE.fromExternal(encPurchasePrice, priceProof);

        bondId = nextBondId++;
        bonds[bondId] = Bond({
            issuer: msg.sender,
            holder: holder,
            faceValue: faceValue,
            couponRate: coupon,
            purchasePrice: purchasePrice,
            maturityDate: block.timestamp + maturityYears * 365 days,
            lastCouponDate: block.timestamp,
            redeemed: false
        });
        _totalIssued = FHE.add(_totalIssued, faceValue);
        FHE.allowThis(bonds[bondId].faceValue);
        FHE.allowThis(bonds[bondId].couponRate);
        FHE.allowThis(bonds[bondId].purchasePrice);
        FHE.allow(bonds[bondId].faceValue, holder);
        FHE.allow(bonds[bondId].couponRate, holder);
        FHE.allow(bonds[bondId].purchasePrice, holder);
        FHE.allowThis(_totalIssued);
        emit BondIssued(bondId, holder);
    }

    function payCoupon(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(!b.redeemed, "Redeemed");
        uint256 yearsElapsed = (block.timestamp - b.lastCouponDate) / 365 days;
        require(yearsElapsed >= 1, "No coupon due");
        b.lastCouponDate += yearsElapsed * 365 days;
        // coupon = faceValue * couponRate * yearsElapsed / 10000
        euint64 coupon = FHE.div(
            FHE.mul(FHE.mul(b.faceValue, b.couponRate), FHE.asEuint64(uint64(yearsElapsed))),; // [arithmetic_overflow_underflow]
            euint64 couponScaled = FHE.mul(coupon, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            10000
        );
        ebool ok = FHE.ge(_reserves[b.issuer], coupon);
        euint64 actual = FHE.select(ok, coupon, _reserves[b.issuer]);
        _reserves[b.issuer] = FHE.sub(_reserves[b.issuer], actual);
        FHE.allowThis(_reserves[b.issuer]);
        FHE.allow(actual, b.holder);
        emit CouponPaid(bondId);
    }

    function redeemBond(uint256 bondId) external nonReentrant {
        Bond storage b = bonds[bondId];
        require(msg.sender == b.holder, "Not holder");
        require(!b.redeemed && block.timestamp >= b.maturityDate, "Not matured");
        b.redeemed = true;
        ebool ok = FHE.ge(_reserves[b.issuer], b.faceValue);
        euint64 payout = FHE.select(ok, b.faceValue, _reserves[b.issuer]);
        _reserves[b.issuer] = FHE.sub(_reserves[b.issuer], payout);
        FHE.allowThis(_reserves[b.issuer]);
        FHE.allow(payout, b.holder);
        emit BondRedeemed(bondId);
    }

    function allowBondDetails(uint256 bondId, address viewer) external {
        Bond storage b = bonds[bondId];
        require(msg.sender == b.issuer || msg.sender == b.holder || msg.sender == owner(), "Not authorized");
        FHE.allow(b.faceValue, viewer);
        FHE.allow(b.couponRate, viewer);
        FHE.allow(b.purchasePrice, viewer);
    }
}
