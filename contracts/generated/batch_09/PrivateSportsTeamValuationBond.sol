// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSportsTeamValuationBond
/// @notice Encrypted sports franchise valuation bonds: hidden team revenue multiples,
///         confidential media rights income streams, private stadium monetization data,
///         and encrypted performance-linked coupon adjustments.
contract PrivateSportsTeamValuationBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SportLeague { NFL, NBA, MLB, EPL, LaLiga, F1, NRL }
    enum BondStatus { Issuance, Active, MaturityReached, Redeemed }

    struct TeamBond {
        address teamOwner;
        SportLeague league;
        string teamName;
        euint64 bondFaceValueUSD;      // encrypted face value
        euint64 mediaRightsIncomeUSD;  // encrypted media rights revenue
        euint64 ticketingRevenueUSD;   // encrypted ticketing revenue
        euint64 valuationMultiple;     // encrypted EV/Revenue multiple
        euint16 baseCouponBps;         // encrypted base coupon rate
        euint16 performanceBonusBps;   // encrypted performance-linked bonus
        euint64 outstandingNotionalUSD;// encrypted outstanding amount
        BondStatus status;
        uint256 issuanceDate;
        uint256 maturityDate;
    }

    struct BondInvestor {
        uint256 bondId;
        address investor;
        euint64 investedAmountUSD;     // encrypted investment
        euint64 couponEarnedUSD;       // encrypted coupon accrued
        euint64 performanceBonusEarnedUSD; // encrypted performance bonus
        uint256 investedAt;
    }

    mapping(uint256 => TeamBond) private bonds;
    mapping(uint256 => BondInvestor) private investors;
    mapping(address => bool) public isSportsFinancier;

    uint256 public bondCount;
    uint256 public investorCount;
    euint64 private _totalBondMarketUSD;

    event TeamBondIssued(uint256 indexed id, SportLeague league, string teamName);
    event InvestorSubscribed(uint256 indexed investorId, uint256 bondId);
    event CouponDistributed(uint256 indexed bondId, uint256 distributedAt);

    modifier onlySportsFinancier() {
        require(isSportsFinancier[msg.sender] || msg.sender == owner(), "Not sports financier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBondMarketUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalBondMarketUSD);
        isSportsFinancier[msg.sender] = true;
    }

    function addFinancier(address f) external onlyOwner { isSportsFinancier[f] = true; }

    function issueBond(
        address teamOwner, SportLeague league, string calldata teamName,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint64 encMediaRights, bytes calldata mrProof,
        externalEuint64 encTicketing, bytes calldata tProof,
        externalEuint64 encMultiple, bytes calldata mulProof,
        externalEuint16 encBaseCoupon, bytes calldata bcProof,
        uint256 maturityDays
    ) external onlySportsFinancier returns (uint256 id) {
        euint64 faceValue = FHE.fromExternal(encFaceValue, fvProof);
        euint64 mediaRights = FHE.fromExternal(encMediaRights, mrProof);
        euint64 ticketing = FHE.fromExternal(encTicketing, tProof);
        euint64 multiple = FHE.fromExternal(encMultiple, mulProof);
        euint16 baseCoupon = FHE.fromExternal(encBaseCoupon, bcProof);
        id = bondCount++;
        TeamBond storage _s0 = bonds[id];
        _s0.teamOwner = teamOwner;
        _s0.league = league;
        _s0.teamName = teamName;
        _s0.bondFaceValueUSD = faceValue;
        _s0.mediaRightsIncomeUSD = mediaRights;
        _s0.ticketingRevenueUSD = ticketing;
        _s0.valuationMultiple = multiple;
        _s0.baseCouponBps = baseCoupon;
        _s0.performanceBonusBps = FHE.asEuint16(0);
        _s0.outstandingNotionalUSD = faceValue;
        _s0.status = BondStatus.Issuance;
        _s0.issuanceDate = block.timestamp;
        _s0.maturityDate = block.timestamp + maturityDays * 1 days;
        _totalBondMarketUSD = FHE.add(_totalBondMarketUSD, faceValue);
        FHE.allowThis(bonds[id].bondFaceValueUSD); FHE.allow(bonds[id].bondFaceValueUSD, teamOwner);
        FHE.allowThis(bonds[id].mediaRightsIncomeUSD); FHE.allow(bonds[id].mediaRightsIncomeUSD, teamOwner);
        FHE.allowThis(bonds[id].ticketingRevenueUSD); FHE.allow(bonds[id].ticketingRevenueUSD, teamOwner);
        FHE.allowThis(bonds[id].valuationMultiple);
        FHE.allowThis(bonds[id].baseCouponBps);
        FHE.allowThis(bonds[id].performanceBonusBps);
        FHE.allowThis(bonds[id].outstandingNotionalUSD); FHE.allow(bonds[id].outstandingNotionalUSD, teamOwner);
        FHE.allowThis(_totalBondMarketUSD);
        emit TeamBondIssued(id, league, teamName);
    }

    function subscribeInvestor(
        uint256 bondId,
        externalEuint64 encInvestment, bytes calldata proof
    ) external nonReentrant returns (uint256 invId) {
        TeamBond storage b = bonds[bondId];
        require(b.status == BondStatus.Issuance || b.status == BondStatus.Active, "Not accepting investors");
        euint64 investment = FHE.fromExternal(encInvestment, proof);
        invId = investorCount++;
        investors[invId] = BondInvestor({
            bondId: bondId, investor: msg.sender, investedAmountUSD: investment,
            couponEarnedUSD: FHE.asEuint64(0), performanceBonusEarnedUSD: FHE.asEuint64(0),
            investedAt: block.timestamp
        });
        FHE.allowThis(investors[invId].investedAmountUSD); FHE.allow(investors[invId].investedAmountUSD, msg.sender); FHE.allow(investors[invId].investedAmountUSD, b.teamOwner);
        FHE.allowThis(investors[invId].couponEarnedUSD); FHE.allow(investors[invId].couponEarnedUSD, msg.sender);
        FHE.allowThis(investors[invId].performanceBonusEarnedUSD); FHE.allow(investors[invId].performanceBonusEarnedUSD, msg.sender);
        emit InvestorSubscribed(invId, bondId);
    }

    function distributeCoupon(
        uint256 bondId,
        externalEuint16 encPerfBonus, bytes calldata pbProof
    ) external onlySportsFinancier {
        TeamBond storage b = bonds[bondId];
        b.performanceBonusBps = FHE.fromExternal(encPerfBonus, pbProof);
        FHE.allowThis(b.performanceBonusBps);
        emit CouponDistributed(bondId, block.timestamp);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalBondMarketUSD, viewer);
    }
}
