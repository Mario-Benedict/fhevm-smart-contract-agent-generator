// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAviationFuelHedgingProgram
/// @notice Encrypted aviation fuel hedging: hidden airline fuel consumption forecasts,
///         confidential hedge notional quantities, private option premium payouts,
///         and encrypted refinery pricing differentials by grade.
contract PrivateAviationFuelHedgingProgram is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum HedgeInstrument { Swap, CapOption, CollarOption, CallSpread, PutSpread }
    enum JetFuelGrade { JetA, JetA1, Avgas100LL, JetB, Biojet50 }

    struct FuelHedge {
        address airline;
        address counterparty;
        HedgeInstrument instrument;
        JetFuelGrade fuelGrade;
        string tradeRef;
        euint64 notionalGallons;       // encrypted notional quantity
        euint64 strikePrice_USDgal;    // encrypted strike price
        euint64 optionPremiumUSD;      // encrypted premium paid
        euint64 currentSpotUSD;        // encrypted spot price
        euint64 markToMarketUSD;       // encrypted MTM PnL
        euint64 settlementPayoutUSD;   // encrypted settlement
        euint16 hedgeRatioBps;         // encrypted hedge ratio
        bool settled;
        uint256 maturityDate;
    }

    mapping(uint256 => FuelHedge) private hedges;
    mapping(address => bool) public isFuelTreasury;

    uint256 public hedgeCount;
    euint64 private _totalNotionalGallons;
    euint64 private _totalPremiumsPaidUSD;
    euint64 private _totalSettlementsUSD;

    event HedgeTraded(uint256 indexed id, HedgeInstrument instrument, JetFuelGrade fuelGrade);
    event HedgeSettled(uint256 indexed id, uint256 settledAt);

    modifier onlyFuelTreasury() {
        require(isFuelTreasury[msg.sender] || msg.sender == owner(), "Not fuel treasury");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNotionalGallons = FHE.asEuint64(0);
        _totalPremiumsPaidUSD = FHE.asEuint64(0);
        _totalSettlementsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalNotionalGallons);
        FHE.allowThis(_totalPremiumsPaidUSD);
        FHE.allowThis(_totalSettlementsUSD);
        isFuelTreasury[msg.sender] = true;
    }

    function addFuelTreasury(address ft) external onlyOwner { isFuelTreasury[ft] = true; }

    function tradeHedge(
        address counterparty, HedgeInstrument instrument, JetFuelGrade fuelGrade, string calldata tradeRef,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint16 encHedgeRatio, bytes calldata hrProof,
        uint256 maturityDays
    ) external returns (uint256 id) {
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint16 hedgeRatio = FHE.fromExternal(encHedgeRatio, hrProof);
        id = hedgeCount++;
        FuelHedge storage _s0 = hedges[id];
        _s0.airline = msg.sender;
        _s0.counterparty = counterparty;
        _s0.instrument = instrument;
        _s0.fuelGrade = fuelGrade;
        _s0.tradeRef = tradeRef;
        _s0.notionalGallons = notional;
        _s0.strikePrice_USDgal = strike;
        _s0.optionPremiumUSD = premium;
        _s0.currentSpotUSD = FHE.asEuint64(0);
        _s0.markToMarketUSD = FHE.asEuint64(0);
        _s0.settlementPayoutUSD = FHE.asEuint64(0);
        _s0.hedgeRatioBps = hedgeRatio;
        _s0.settled = false;
        _s0.maturityDate = block.timestamp + maturityDays * 1 days;
        _totalNotionalGallons = FHE.add(_totalNotionalGallons, notional);
        _totalPremiumsPaidUSD = FHE.add(_totalPremiumsPaidUSD, premium);
        FHE.allowThis(hedges[id].notionalGallons); FHE.allow(hedges[id].notionalGallons, msg.sender);
        FHE.allowThis(hedges[id].strikePrice_USDgal); FHE.allow(hedges[id].strikePrice_USDgal, msg.sender);
        FHE.allowThis(hedges[id].optionPremiumUSD); FHE.allow(hedges[id].optionPremiumUSD, msg.sender);
        FHE.allowThis(hedges[id].currentSpotUSD);
        FHE.allowThis(hedges[id].markToMarketUSD); FHE.allow(hedges[id].markToMarketUSD, msg.sender);
        FHE.allowThis(hedges[id].settlementPayoutUSD); FHE.allow(hedges[id].settlementPayoutUSD, msg.sender);
        FHE.allowThis(hedges[id].hedgeRatioBps); FHE.allow(hedges[id].hedgeRatioBps, msg.sender);
        FHE.allowThis(_totalNotionalGallons);
        FHE.allowThis(_totalPremiumsPaidUSD);
        emit HedgeTraded(id, instrument, fuelGrade);
    }

    function settleHedge(
        uint256 hedgeId,
        externalEuint64 encSpotAtMaturity, bytes calldata sProof,
        externalEuint64 encSettlement, bytes calldata settleProof
    ) external onlyFuelTreasury nonReentrant {
        FuelHedge storage h = hedges[hedgeId];
        require(!h.settled, "Already settled");
        h.currentSpotUSD = FHE.fromExternal(encSpotAtMaturity, sProof);
        h.settlementPayoutUSD = FHE.fromExternal(encSettlement, settleProof);
        ebool airlineGains = FHE.gt(h.strikePrice_USDgal, h.currentSpotUSD);
        h.markToMarketUSD = FHE.select(airlineGains, h.settlementPayoutUSD, FHE.asEuint64(0));
        h.settled = true;
        _totalSettlementsUSD = FHE.add(_totalSettlementsUSD, h.settlementPayoutUSD);
        FHE.allowThis(h.currentSpotUSD); FHE.allow(h.currentSpotUSD, h.airline);
        FHE.allowThis(h.settlementPayoutUSD); FHE.allow(h.settlementPayoutUSD, h.airline);
        FHE.allowThis(h.markToMarketUSD); FHE.allow(h.markToMarketUSD, h.airline);
        FHE.allowThis(_totalSettlementsUSD);
        emit HedgeSettled(hedgeId, block.timestamp);
    }

    function allowHedgeStats(address viewer) external onlyOwner {
        FHE.allow(_totalNotionalGallons, viewer);
        FHE.allow(_totalPremiumsPaidUSD, viewer);
        FHE.allow(_totalSettlementsUSD, viewer);
    }
}
