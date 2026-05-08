// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAviationFuelHedge
/// @notice Airlines hedge jet-fuel price exposure using encrypted forward contracts.
///         Each hedge encodes volume, strike price, and settlement amount privately.
///         An oracle posts encrypted spot prices; settlement computed on-chain in FHE.
contract PrivateAviationFuelHedge is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum HedgeStatus { Open, Settled, Cancelled }

    struct FuelHedge {
        address airline;
        string iataCode;                // e.g. "AA", "DL"
        euint64 volumeBarrels;          // encrypted barrels to hedge
        euint64 strikePriceUSDCents;    // encrypted strike price (cents per barrel)
        euint64 currentSpotUSDCents;    // encrypted latest oracle spot price
        euint64 settlementPnLCents;     // encrypted P&L at settlement
        uint256 maturity;
        HedgeStatus status;
    }

    mapping(uint256 => FuelHedge) private hedges;
    mapping(address => uint256[]) private airlineHedges;
    mapping(address => bool) public isApprovedAirline;
    mapping(address => bool) public isPriceOracle;

    uint256 public hedgeCount;
    euint64 private _totalHedgedVolume;
    euint64 private _totalSettledPnL;

    event HedgeOpened(uint256 indexed id, string iataCode);
    event SpotUpdated(uint256 indexed id);
    event HedgeSettled(uint256 indexed id, address airline);
    event HedgeCancelled(uint256 indexed id);

    modifier onlyOracle() {
        require(isPriceOracle[msg.sender] || msg.sender == owner(), "Not oracle");
        _;
    }

    modifier onlyAirline(uint256 id) {
        require(hedges[id].airline == msg.sender, "Not airline");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalHedgedVolume = FHE.asEuint64(0);
        _totalSettledPnL = FHE.asEuint64(0);
        FHE.allowThis(_totalHedgedVolume);
        FHE.allowThis(_totalSettledPnL);
        isPriceOracle[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isPriceOracle[o] = true; }
    function approveAirline(address a) external onlyOwner { isApprovedAirline[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function openHedge(
        string calldata iataCode,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encStrike, bytes calldata sProof,
        uint256 maturityDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isApprovedAirline[msg.sender], "Not approved airline");
        euint64 volume = FHE.fromExternal(encVolume, vProof);
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        id = hedgeCount++;
        hedges[id] = FuelHedge({
            airline: msg.sender,
            iataCode: iataCode,
            volumeBarrels: volume,
            strikePriceUSDCents: strike,
            currentSpotUSDCents: FHE.asEuint64(0),
            settlementPnLCents: FHE.asEuint64(0),
            maturity: block.timestamp + maturityDays * 1 days,
            status: HedgeStatus.Open
        });
        _totalHedgedVolume = FHE.add(_totalHedgedVolume, volume);
        FHE.allowThis(hedges[id].volumeBarrels);
        FHE.allow(hedges[id].volumeBarrels, msg.sender);
        FHE.allowThis(hedges[id].strikePriceUSDCents);
        FHE.allow(hedges[id].strikePriceUSDCents, msg.sender);
        FHE.allowThis(hedges[id].currentSpotUSDCents);
        FHE.allowThis(hedges[id].settlementPnLCents);
        FHE.allowThis(_totalHedgedVolume);
        airlineHedges[msg.sender].push(id);
        emit HedgeOpened(id, iataCode);
    }

    function updateSpot(
        uint256 id,
        externalEuint64 encSpot, bytes calldata proof
    ) external onlyOracle {
        FuelHedge storage h = hedges[id];
        require(h.status == HedgeStatus.Open, "Not open");
        euint64 spot = FHE.fromExternal(encSpot, proof);
        h.currentSpotUSDCents = spot;
        FHE.allowThis(h.currentSpotUSDCents);
        FHE.allow(h.currentSpotUSDCents, h.airline);
        emit SpotUpdated(id);
    }

    function settle(uint256 id) external onlyOracle nonReentrant {
        FuelHedge storage h = hedges[id];
        require(h.status == HedgeStatus.Open, "Not open");
        require(block.timestamp >= h.maturity, "Not matured");
        // PnL = (strike - spot) * volume  (airline gains if spot > strike via fixed price)
        ebool airlineGains = FHE.gt(h.currentSpotUSDCents, h.strikePriceUSDCents);
        euint64 diff = FHE.select(
            airlineGains,
            FHE.sub(h.currentSpotUSDCents, h.strikePriceUSDCents),
            FHE.sub(h.strikePriceUSDCents, h.currentSpotUSDCents)
        );
        euint64 pnl = FHE.mul(diff, h.volumeBarrels);
        h.settlementPnLCents = pnl;
        h.status = HedgeStatus.Settled;
        _totalSettledPnL = FHE.add(_totalSettledPnL, pnl);
        FHE.allowThis(h.settlementPnLCents);
        FHE.allow(h.settlementPnLCents, h.airline);
        FHE.allowThis(_totalSettledPnL);
        emit HedgeSettled(id, h.airline);
    }

    function cancel(uint256 id) external onlyAirline(id) {
        FuelHedge storage h = hedges[id];
        require(h.status == HedgeStatus.Open, "Not open");
        h.status = HedgeStatus.Cancelled;
        emit HedgeCancelled(id);
    }

    function allowHedgeDetails(uint256 id, address viewer) external {
        FuelHedge storage h = hedges[id];
        require(msg.sender == h.airline || isPriceOracle[msg.sender], "Unauthorized");
        FHE.allow(h.volumeBarrels, viewer);
        FHE.allow(h.strikePriceUSDCents, viewer);
        FHE.allow(h.currentSpotUSDCents, viewer);
        FHE.allow(h.settlementPnLCents, viewer);
    }

    function allowStats(address viewer) external onlyOwner {
        FHE.allow(_totalHedgedVolume, viewer);
        FHE.allow(_totalSettledPnL, viewer);
    }
}
