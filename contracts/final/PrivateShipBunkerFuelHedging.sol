// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateShipBunkerFuelHedging
/// @notice Maritime fuel (bunker) hedging: encrypted bunker fuel consumption forecasts,
///         encrypted hedge ratios, encrypted FFA (Forward Freight Agreements) positions, and private fuel cost management.
contract PrivateShipBunkerFuelHedging is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FuelGrade { VLSFO, HSFO, MGO, LNG, METHANOL }

    struct VesselFuelProfile {
        string imoNumber;
        address shipowner;
        FuelGrade primaryFuel;
        euint64 dailyConsumptionTonnes;  // encrypted daily consumption
        euint64 routeDistanceNm;         // encrypted typical voyage distance
        euint64 expectedVoyages;         // encrypted annual voyage count
        euint64 totalFuelBudgetUSD;      // encrypted annual fuel budget
        euint64 hedgeRatioBps;           // encrypted hedge ratio (what % to hedge)
    }

    struct BunkerHedge {
        uint256 vesselId;
        FuelGrade grade;
        euint64 hedgedTonnes;          // encrypted quantity hedged
        euint64 strikePrice;           // encrypted fixed price per tonne
        euint64 marketPrice;           // encrypted current market price
        euint64 markToMarketPnL;       // encrypted MTM gain/loss
        euint64 premiumPaidUSD;        // encrypted option premium / swap cost
        uint256 expiryDate;
        bool settled;
        bool exercised;
    }

    struct MarketData {
        FuelGrade grade;
        euint64 spotPriceUSD;          // encrypted current spot price/tonne
        euint64 volatilityBps;         // encrypted 30-day volatility
        euint64 forwardPriceDiff;      // encrypted contango/backwardation
        uint256 lastUpdated;
    }

    mapping(uint256 => VesselFuelProfile) private vessels;
    mapping(uint256 => BunkerHedge) private hedges;
    mapping(uint256 => MarketData) private markets; // indexed by FuelGrade
    uint256 public vesselCount;
    uint256 public hedgeCount;
    euint64 private _totalHedgedExposure;
    euint64 private _totalPremiumPaid;
    mapping(address => bool) public isBunkerTrader;
    mapping(address => bool) public isMarketOracle;

    event VesselRegistered(uint256 indexed id, string imoNumber, FuelGrade grade);
    event HedgeOpened(uint256 indexed hedgeId, uint256 vesselId, FuelGrade grade);
    event HedgeSettled(uint256 indexed hedgeId, bool exercised);
    event MarketUpdated(uint256 indexed gradeId);
    event MTMUpdated(uint256 indexed hedgeId);

    constructor() Ownable(msg.sender) {
        _totalHedgedExposure = FHE.asEuint64(0);
        _totalPremiumPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalHedgedExposure);
        FHE.allowThis(_totalPremiumPaid);
        isBunkerTrader[msg.sender] = true;
        isMarketOracle[msg.sender] = true;
    }

    function addTrader(address t) external onlyOwner { isBunkerTrader[t] = true; }
    function addOracle(address o) external onlyOwner { isMarketOracle[o] = true; }

    function registerVessel(
        string calldata imoNumber, FuelGrade grade,
        externalEuint64 encConsumption, bytes calldata cProof,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encHedgeRatio, bytes calldata hrProof
    ) external returns (uint256 id) {
        euint64 consumption = FHE.fromExternal(encConsumption, cProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 hedgeRatio = FHE.fromExternal(encHedgeRatio, hrProof);
        id = vesselCount++;
        vessels[id] = VesselFuelProfile({
            imoNumber: imoNumber, shipowner: msg.sender, primaryFuel: grade,
            dailyConsumptionTonnes: consumption, routeDistanceNm: FHE.asEuint64(0),
            expectedVoyages: FHE.asEuint64(12), totalFuelBudgetUSD: budget,
            hedgeRatioBps: hedgeRatio
        });
        FHE.allowThis(vessels[id].dailyConsumptionTonnes);
        FHE.allowThis(vessels[id].totalFuelBudgetUSD);
        FHE.allowThis(vessels[id].hedgeRatioBps);
        FHE.allow(vessels[id].totalFuelBudgetUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalHedgedExposure, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPremiumPaid, msg.sender); // [acl_misconfig]
        emit VesselRegistered(id, imoNumber, grade);
    }

    function openHedge(
        uint256 vesselId, FuelGrade grade, uint256 expiry,
        externalEuint64 encTonnes, bytes calldata tProof,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encPremium, bytes calldata pProof
    ) external nonReentrant returns (uint256 hedgeId) {
        require(isBunkerTrader[msg.sender] || vessels[vesselId].shipowner == msg.sender, "Not authorized");
        euint64 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        // Apply hedge ratio from vessel profile
        euint64 hedgedTonnes = FHE.div(FHE.mul(tonnes, vessels[vesselId].hedgeRatioBps), 10000);
        hedgeId = hedgeCount++;
        hedges[hedgeId].vesselId = vesselId;
        hedges[hedgeId].grade = grade;
        hedges[hedgeId].hedgedTonnes = hedgedTonnes;
        hedges[hedgeId].strikePrice = strike;
        hedges[hedgeId].marketPrice = FHE.asEuint64(0);
        hedges[hedgeId].markToMarketPnL = FHE.asEuint64(0);
        hedges[hedgeId].premiumPaidUSD = premium;
        hedges[hedgeId].expiryDate = expiry;
        hedges[hedgeId].settled = false;
        hedges[hedgeId].exercised = false;
        _totalHedgedExposure = FHE.add(_totalHedgedExposure, FHE.mul(hedgedTonnes, strike));
        _totalPremiumPaid = FHE.add(_totalPremiumPaid, premium);
        FHE.allowThis(hedges[hedgeId].hedgedTonnes);
        FHE.allowThis(hedges[hedgeId].strikePrice);
        FHE.allowThis(hedges[hedgeId].markToMarketPnL);
        FHE.allowThis(hedges[hedgeId].premiumPaidUSD);
        FHE.allow(hedges[hedgeId].markToMarketPnL, vessels[vesselId].shipowner);
        FHE.allowThis(_totalHedgedExposure);
        FHE.allowThis(_totalPremiumPaid);
        emit HedgeOpened(hedgeId, vesselId, grade);
    }

    function updateMarket(
        uint256 gradeId,
        externalEuint64 encSpot, bytes calldata spProof,
        externalEuint64 encVolatility, bytes calldata volProof,
        externalEuint64 encForwardDiff, bytes calldata fdProof
    ) external {
        require(isMarketOracle[msg.sender], "Not oracle");
        euint64 spot = FHE.fromExternal(encSpot, spProof);
        euint64 vol = FHE.fromExternal(encVolatility, volProof);
        euint64 fwd = FHE.fromExternal(encForwardDiff, fdProof);
        markets[gradeId] = MarketData({
            grade: FuelGrade(gradeId), spotPriceUSD: spot, volatilityBps: vol,
            forwardPriceDiff: fwd, lastUpdated: block.timestamp
        });
        FHE.allowThis(markets[gradeId].spotPriceUSD);
        FHE.allowThis(markets[gradeId].volatilityBps);
        FHE.allowThis(markets[gradeId].forwardPriceDiff);
        emit MarketUpdated(gradeId);
    }

    function markToMarket(uint256 hedgeId, uint256 gradeId) external {
        require(isBunkerTrader[msg.sender], "Not trader");
        BunkerHedge storage hedge = hedges[hedgeId];
        require(!hedge.settled, "Settled");
        euint64 spot = markets[gradeId].spotPriceUSD;
        hedge.marketPrice = spot;
        // PnL = (strike - spot) * tonnes (for a long call)
        ebool inTheMoney = FHE.gt(spot, hedge.strikePrice);
        hedge.markToMarketPnL = FHE.select(inTheMoney,
            FHE.mul(FHE.sub(spot, hedge.strikePrice), hedge.hedgedTonnes),
            FHE.asEuint64(0));
        FHE.allowThis(hedge.marketPrice);
        FHE.allowThis(hedge.markToMarketPnL);
        FHE.allow(hedge.markToMarketPnL, vessels[hedge.vesselId].shipowner);
        emit MTMUpdated(hedgeId);
    }

    function settleHedge(uint256 hedgeId, bool exercise) external nonReentrant {
        require(isBunkerTrader[msg.sender], "Not trader");
        BunkerHedge storage hedge = hedges[hedgeId];
        require(block.timestamp >= hedge.expiryDate && !hedge.settled, "Not ready");
        hedge.settled = true;
        hedge.exercised = exercise;
        FHE.allow(hedge.markToMarketPnL, vessels[hedge.vesselId].shipowner);
        emit HedgeSettled(hedgeId, exercise);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}