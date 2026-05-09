// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedMunicipalBondIssuance
/// @notice Municipal bond platform: encrypted face values, encrypted coupon rates,
///         encrypted investor allocations, and sealed-book order building.
contract EncryptedMunicipalBondIssuance is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BondStatus { Announced, OrderBuilding, Priced, Settled, Matured, Defaulted }

    struct MunicipalBond {
        string issuerName;
        string purpose;                // e.g. "School Infrastructure"
        string cusip;
        euint64 faceValueUSD;          // encrypted total face value
        euint16 couponRateBps;         // encrypted coupon rate
        euint64 yieldToMaturityBps;    // encrypted YTM
        euint64 totalOrdersUSD;        // encrypted total demand
        euint64 totalAllocatedUSD;     // encrypted total allocated
        uint256 maturityDate;
        uint256 settlementDate;
        BondStatus status;
        address issuer;
    }

    struct BondOrder {
        uint256 bondId;
        address investor;
        euint64 orderAmountUSD;        // encrypted order size
        euint64 allocatedAmountUSD;    // encrypted final allocation
        euint64 accruedCouponUSD;      // encrypted accrued coupon
        bool settled;
    }

    mapping(uint256 => MunicipalBond) private bonds;
    mapping(uint256 => BondOrder) private orders;
    mapping(address => bool) public isUnderwriter;
    mapping(address => bool) public isQualifiedInvestor;
    uint256 public bondCount;
    uint256 public orderCount;
    euint64 private _totalIssuanceVolume;

    event BondAnnounced(uint256 indexed id, string issuer, string cusip);
    event OrderSubmitted(uint256 indexed orderId, uint256 bondId, address investor);
    event BondPriced(uint256 indexed bondId);
    event BondSettled(uint256 indexed bondId);
    event CouponPaid(uint256 indexed orderId, address investor);

    modifier onlyUnderwriter() {
        require(isUnderwriter[msg.sender] || msg.sender == owner(), "Not underwriter");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalIssuanceVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalIssuanceVolume);
        isUnderwriter[msg.sender] = true;
    }

    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function addInvestor(address i) external onlyOwner { isQualifiedInvestor[i] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function announceBond(
        string calldata issuerName, string calldata purpose, string calldata cusip, address issuer,
        externalEuint64 encFaceValue, bytes calldata fvPf,
        externalEuint16 encCoupon, bytes calldata cPf,
        uint256 maturityDays
    ) external onlyUnderwriter whenNotPaused returns (uint256 id) {
        euint64 faceValue = FHE.fromExternal(encFaceValue, fvPf);
        euint16 coupon = FHE.fromExternal(encCoupon, cPf);
        id = bondCount++;
        MunicipalBond storage _s0 = bonds[id];
        _s0.issuerName = issuerName;
        _s0.purpose = purpose;
        _s0.cusip = cusip;
        _s0.faceValueUSD = faceValue;
        _s0.couponRateBps = coupon;
        _s0.yieldToMaturityBps = FHE.asEuint64(0);
        _s0.totalOrdersUSD = FHE.asEuint64(0);
        _s0.totalAllocatedUSD = FHE.asEuint64(0);
        _s0.maturityDate = block.timestamp + maturityDays * 1 days;
        _s0.settlementDate = 0;
        _s0.status = BondStatus.Announced;
        _s0.issuer = issuer;
        FHE.allowThis(bonds[id].faceValueUSD);
        FHE.allow(bonds[id].faceValueUSD, issuer);
        FHE.allowThis(bonds[id].couponRateBps);
        FHE.allowThis(bonds[id].yieldToMaturityBps);
        FHE.allowThis(bonds[id].totalOrdersUSD);
        FHE.allowThis(bonds[id].totalAllocatedUSD);
        emit BondAnnounced(id, issuerName, cusip);
    }

    function submitOrder(
        uint256 bondId,
        externalEuint64 encOrderAmt, bytes calldata proof
    ) external whenNotPaused nonReentrant returns (uint256 orderId) {
        require(isQualifiedInvestor[msg.sender], "Not qualified investor");
        require(bonds[bondId].status == BondStatus.OrderBuilding, "Not in order building");
        euint64 orderAmt = FHE.fromExternal(encOrderAmt, proof);
        orderId = orderCount++;
        orders[orderId] = BondOrder({
            bondId: bondId, investor: msg.sender, orderAmountUSD: orderAmt,
            allocatedAmountUSD: FHE.asEuint64(0), accruedCouponUSD: FHE.asEuint64(0), settled: false
        });
        bonds[bondId].totalOrdersUSD = FHE.add(bonds[bondId].totalOrdersUSD, orderAmt);
        FHE.allowThis(orders[orderId].orderAmountUSD);
        FHE.allow(orders[orderId].orderAmountUSD, msg.sender);
        FHE.allowThis(orders[orderId].allocatedAmountUSD);
        FHE.allow(orders[orderId].allocatedAmountUSD, msg.sender);
        FHE.allowThis(orders[orderId].accruedCouponUSD);
        FHE.allow(orders[orderId].accruedCouponUSD, msg.sender);
        FHE.allowThis(bonds[bondId].totalOrdersUSD);
        emit OrderSubmitted(orderId, bondId, msg.sender);
    }

    function openOrderBuilding(uint256 bondId) external onlyUnderwriter {
        bonds[bondId].status = BondStatus.OrderBuilding;
    }

    function priceBond(
        uint256 bondId,
        externalEuint64 encYTM, bytes calldata proof
    ) external onlyUnderwriter {
        euint64 ytm = FHE.fromExternal(encYTM, proof);
        bonds[bondId].yieldToMaturityBps = ytm;
        bonds[bondId].status = BondStatus.Priced;
        FHE.allowThis(bonds[bondId].yieldToMaturityBps);
        emit BondPriced(bondId);
    }

    function allocateOrder(
        uint256 orderId,
        externalEuint64 encAllocation, bytes calldata proof
    ) external onlyUnderwriter {
        BondOrder storage o = orders[orderId];
        MunicipalBond storage b = bonds[o.bondId];
        euint64 allocation = FHE.fromExternal(encAllocation, proof);
        ebool withinFace = FHE.le(
            FHE.add(b.totalAllocatedUSD, allocation), b.faceValueUSD
        );
        euint64 actual = FHE.select(withinFace, allocation, FHE.asEuint64(0));
        o.allocatedAmountUSD = actual;
        b.totalAllocatedUSD = FHE.add(b.totalAllocatedUSD, actual);
        FHE.allowThis(o.allocatedAmountUSD);
        FHE.allow(o.allocatedAmountUSD, o.investor);
        FHE.allowThis(b.totalAllocatedUSD);
    }

    function settleIssuance(uint256 bondId) external onlyUnderwriter {
        MunicipalBond storage b = bonds[bondId];
        require(b.status == BondStatus.Priced, "Not priced");
        b.status = BondStatus.Settled;
        b.settlementDate = block.timestamp;
        _totalIssuanceVolume = FHE.add(_totalIssuanceVolume, b.totalAllocatedUSD);
        FHE.allowThis(_totalIssuanceVolume);
        FHE.allow(b.totalAllocatedUSD, b.issuer);
        emit BondSettled(bondId);
    }

    function payCoupon(
        uint256 orderId,
        externalEuint64 encCouponAmt, bytes calldata proof
    ) external onlyUnderwriter {
        BondOrder storage o = orders[orderId];
        euint64 coupon = FHE.fromExternal(encCouponAmt, proof);
        o.accruedCouponUSD = FHE.add(o.accruedCouponUSD, coupon);
        FHE.allowThis(o.accruedCouponUSD);
        FHE.allow(o.accruedCouponUSD, o.investor);
        FHE.allow(coupon, o.investor);
        emit CouponPaid(orderId, o.investor);
    }

    function allowBondDetails(uint256 bondId, address viewer) external onlyUnderwriter {
        FHE.allow(bonds[bondId].faceValueUSD, viewer);
        FHE.allow(bonds[bondId].couponRateBps, viewer);
        FHE.allow(bonds[bondId].totalOrdersUSD, viewer);
        FHE.allow(bonds[bondId].totalAllocatedUSD, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalIssuanceVolume, viewer);
    }
}
