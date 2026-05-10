// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNaturalDisasterCatastropheBond
/// @notice Encrypted catastrophe bond (cat bond) issuance: hidden peril triggers,
///         confidential expected loss calculations, private investor coupon schedules,
///         and encrypted loss event payout waterfall.
contract PrivateNaturalDisasterCatastropheBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PerilType { Hurricane, Earthquake, WildFire, Flood, PandemicMortality, CyberCatastrophe }
    enum TriggerType { Indemnity, IndustryLoss, Parametric, Modeled }

    struct CatBond {
        address sponsor;
        address specialPurposeVehicle;
        PerilType perilType;
        TriggerType triggerType;
        string bondRef;
        euint64 principalAtRiskUSD;    // encrypted principal
        euint64 couponRateBps;         // encrypted coupon rate
        euint64 expectedLossBps;       // encrypted EL
        euint64 triggerThresholdUSD;   // encrypted trigger threshold
        euint64 totalCouponPaidUSD;    // encrypted coupons paid
        euint64 recoveryAmountUSD;     // encrypted sponsor recovery
        bool triggered;
        uint256 maturityDate;
    }

    struct BondInvestment {
        uint256 catBondId;
        address investor;
        euint64 notionalUSD;           // encrypted investment
        euint64 couponEarnedUSD;       // encrypted coupon earned
        euint64 lossAbsorbedUSD;       // encrypted loss absorbed
        uint256 investedAt;
    }

    mapping(uint256 => CatBond) private catBonds;
    mapping(uint256 => BondInvestment) private bondInvestments;
    mapping(address => bool) public isCatBondManager;

    uint256 public catBondCount;
    uint256 public investmentCount;
    euint64 private _totalPrincipalAtRiskUSD;
    euint64 private _totalCouponsIssuedUSD;

    event CatBondIssued(uint256 indexed id, PerilType peril, TriggerType trigger);
    event CatBondTriggered(uint256 indexed id, uint256 triggeredAt);
    event CatBondMatured(uint256 indexed id);

    modifier onlyCatBondManager() {
        require(isCatBondManager[msg.sender] || msg.sender == owner(), "Not cat bond manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPrincipalAtRiskUSD = FHE.asEuint64(0);
        _totalCouponsIssuedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPrincipalAtRiskUSD);
        FHE.allowThis(_totalCouponsIssuedUSD);
        isCatBondManager[msg.sender] = true;
    }

    function addCatBondManager(address cbm) external onlyOwner { isCatBondManager[cbm] = true; }

    function issueCatBond(
        address spv, PerilType perilType, TriggerType triggerType, string calldata bondRef,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encCoupon, bytes calldata cProof,
        externalEuint64 encEL, bytes calldata elProof,
        externalEuint64 encTrigger, bytes calldata tProof,
        uint256 maturityDays
    ) external returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 principalWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 principalExposure = FHE.sub(principalWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 coupon = FHE.fromExternal(encCoupon, cProof);
        euint64 el = FHE.fromExternal(encEL, elProof);
        euint64 trigger = FHE.fromExternal(encTrigger, tProof);
        id = catBondCount++;
        CatBond storage _s0 = catBonds[id];
        _s0.sponsor = msg.sender;
        _s0.specialPurposeVehicle = spv;
        _s0.perilType = perilType;
        _s0.triggerType = triggerType;
        _s0.bondRef = bondRef;
        _s0.principalAtRiskUSD = principal;
        _s0.couponRateBps = coupon;
        _s0.expectedLossBps = el;
        _s0.triggerThresholdUSD = trigger;
        _s0.totalCouponPaidUSD = FHE.asEuint64(0);
        _s0.recoveryAmountUSD = FHE.asEuint64(0);
        _s0.triggered = false;
        _s0.maturityDate = block.timestamp + maturityDays * 1 days;
        _totalPrincipalAtRiskUSD = FHE.add(_totalPrincipalAtRiskUSD, principal);
        FHE.allowThis(catBonds[id].principalAtRiskUSD); FHE.allow(catBonds[id].principalAtRiskUSD, msg.sender);
        FHE.allowThis(catBonds[id].couponRateBps); FHE.allow(catBonds[id].couponRateBps, msg.sender);
        FHE.allowThis(catBonds[id].expectedLossBps);
        FHE.allowThis(catBonds[id].triggerThresholdUSD);
        FHE.allowThis(catBonds[id].totalCouponPaidUSD);
        FHE.allowThis(catBonds[id].recoveryAmountUSD); FHE.allow(catBonds[id].recoveryAmountUSD, msg.sender);
        FHE.allowThis(_totalPrincipalAtRiskUSD);
        emit CatBondIssued(id, perilType, triggerType);
    }

    function triggerCatBond(
        uint256 catBondId,
        externalEuint64 encRecovery, bytes calldata proof
    ) external onlyCatBondManager nonReentrant {
        CatBond storage cb = catBonds[catBondId];
        require(!cb.triggered, "Already triggered");
        euint64 recovery = FHE.fromExternal(encRecovery, proof);
        cb.recoveryAmountUSD = recovery;
        cb.triggered = true;
        FHE.allowThis(cb.recoveryAmountUSD); FHE.allow(cb.recoveryAmountUSD, cb.sponsor);
        emit CatBondTriggered(catBondId, block.timestamp);
    }

    function investInCatBond(
        uint256 catBondId,
        externalEuint64 encNotional, bytes calldata proof
    ) external nonReentrant returns (uint256 investId) {
        CatBond storage cb = catBonds[catBondId];
        require(!cb.triggered, "Bond triggered");
        euint64 notional = FHE.fromExternal(encNotional, proof);
        investId = investmentCount++;
        bondInvestments[investId] = BondInvestment({
            catBondId: catBondId, investor: msg.sender, notionalUSD: notional,
            couponEarnedUSD: FHE.asEuint64(0), lossAbsorbedUSD: FHE.asEuint64(0),
            investedAt: block.timestamp
        });
        FHE.allowThis(bondInvestments[investId].notionalUSD); FHE.allow(bondInvestments[investId].notionalUSD, msg.sender);
        FHE.allowThis(bondInvestments[investId].couponEarnedUSD); FHE.allow(bondInvestments[investId].couponEarnedUSD, msg.sender);
        FHE.allowThis(bondInvestments[investId].lossAbsorbedUSD); FHE.allow(bondInvestments[investId].lossAbsorbedUSD, msg.sender);
    }

    function allowBondStats(address viewer) external onlyOwner {
        FHE.allow(_totalPrincipalAtRiskUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalPrincipalAtRiskUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCouponsIssuedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCouponsIssuedUSD, viewer);
    }
}
