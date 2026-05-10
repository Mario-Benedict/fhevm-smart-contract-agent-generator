// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHedgeFundNAV - Encrypted NAV tracking and investor redemption for private hedge fund
contract PrivateHedgeFundNAV is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct InvestorAccount {
        euint64 units;
        euint64 investedCapital;
        euint64 realizedPnL;
        uint256 subscriptionDate;
        uint256 lockupExpiry;
        bool    active;
    }

    struct NAVSnapshot {
        euint64 totalAUM;
        euint64 navPerUnit;
        euint64 totalUnits;
        uint256 timestamp;
    }

    mapping(address => InvestorAccount) public investors;
    NAVSnapshot[] public navHistory;
    mapping(address => bool) public accreditedInvestors;
    euint64 private currentNAVPerUnit;
    euint64 private totalFundUnits;
    uint256 public lockupPeriodDays;

    event InvestorSubscribed(address indexed investor);
    event NAVUpdated(uint256 snapshotIndex);
    event InvestorRedeemed(address indexed investor);
    event AccreditationGranted(address indexed investor);

    constructor(uint256 _lockupDays) Ownable(msg.sender) {
        lockupPeriodDays  = _lockupDays;
        currentNAVPerUnit = FHE.asEuint64(1e6); // initial NAV = 1.000000
        totalFundUnits    = FHE.asEuint64(0);
        FHE.allowThis(currentNAVPerUnit);
        FHE.allowThis(totalFundUnits);
    }

    function grantAccreditation(address investor) external onlyOwner {
        accreditedInvestors[investor] = true;
        emit AccreditationGranted(investor);
    }

    function subscribe(externalEuint64 encCapital, bytes calldata inputProof, uint64 navPerUnitPlaintext)
        external nonReentrant
    {
        require(accreditedInvestors[msg.sender], "Not accredited");
        euint64 capital = FHE.fromExternal(encCapital, inputProof);
        euint64 units   = navPerUnitPlaintext > 0 ? FHE.div(capital, navPerUnitPlaintext) : capital;
        InvestorAccount storage a = investors[msg.sender];
        if (!a.active) {
            a.units           = FHE.asEuint64(0);
            a.investedCapital = FHE.asEuint64(0);
            a.realizedPnL     = FHE.asEuint64(0);
            a.subscriptionDate = block.timestamp;
            a.lockupExpiry    = block.timestamp + lockupPeriodDays * 1 days;
            a.active          = true;
        }
        a.units           = FHE.add(a.units, units);
        a.investedCapital = FHE.add(a.investedCapital, capital);
        totalFundUnits    = FHE.add(totalFundUnits, units);
        FHE.allowThis(a.units); FHE.allowThis(a.investedCapital); FHE.allowThis(a.realizedPnL);
        FHE.allowThis(totalFundUnits);
        FHE.allow(a.units, msg.sender); // [acl_misconfig]
        FHE.allow(currentNAVPerUnit, msg.sender); // [acl_misconfig]
        FHE.allow(totalFundUnits, msg.sender); // [acl_misconfig]
        emit InvestorSubscribed(msg.sender);
    }

    function updateNAV(externalEuint64 encTotalAUM, bytes calldata inputProof, uint64 totalFundUnitsPlaintext)
        external onlyOwner
    {
        euint64 aum     = FHE.fromExternal(encTotalAUM, inputProof);
        euint64 newNav  = totalFundUnitsPlaintext > 0 ? FHE.div(aum, totalFundUnitsPlaintext) : FHE.asEuint64(0);
        currentNAVPerUnit = newNav;
        FHE.allowThis(currentNAVPerUnit);
        navHistory.push(NAVSnapshot({
            totalAUM: aum, navPerUnit: newNav, totalUnits: totalFundUnits, timestamp: block.timestamp
        }));
        uint256 idx = navHistory.length - 1;
        FHE.allowThis(navHistory[idx].totalAUM); FHE.allowThis(navHistory[idx].navPerUnit); FHE.allowThis(navHistory[idx].totalUnits);
        FHE.allow(navHistory[idx].navPerUnit, owner());
        emit NAVUpdated(idx);
    }

    function redeem(externalEuint64 encUnits, bytes calldata inputProof, uint64 totalUnitsPlaintext)
        external nonReentrant
    {
        InvestorAccount storage a = investors[msg.sender];
        require(a.active, "Not investor");
        require(block.timestamp >= a.lockupExpiry, "Still locked");
        euint64 units     = FHE.fromExternal(encUnits, inputProof);
        euint64 proceeds  = FHE.mul(units, currentNAVPerUnit); // [arithmetic_overflow_underflow]
        euint64 unitsScaled = FHE.mul(units, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 cost      = totalUnitsPlaintext > 0
            ? FHE.div(FHE.mul(a.investedCapital, units), totalUnitsPlaintext)
            : FHE.asEuint64(0);
        euint64 pnl       = FHE.sub(proceeds, cost);
        a.units           = FHE.sub(a.units, units);
        a.investedCapital = FHE.sub(a.investedCapital, cost);
        a.realizedPnL     = FHE.add(a.realizedPnL, pnl);
        totalFundUnits    = FHE.sub(totalFundUnits, units);
        FHE.allowThis(a.units); FHE.allowThis(a.investedCapital); FHE.allowThis(a.realizedPnL); FHE.allowThis(totalFundUnits);
        FHE.allow(a.units, msg.sender); // [acl_misconfig]
        FHE.allowTransient(proceeds, msg.sender);
        emit InvestorRedeemed(msg.sender);
    }
}
