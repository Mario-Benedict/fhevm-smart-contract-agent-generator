// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedElectricityGridBalancing
/// @notice Electricity grid balancing market: generators bid encrypted generation offers,
///         grid operator dispatches with encrypted marginal prices.
contract EncryptedElectricityGridBalancing is ZamaEthereumConfig, Ownable {
    enum BalancingInterval { FifteenMin, HalfHour, OneHour }

    struct DispatchInterval {
        uint256 intervalStart;
        BalancingInterval duration;
        euint64 targetLoadMW;          // encrypted forecasted demand MW
        euint64 totalOfferedMW;        // encrypted total supply bids
        euint64 marginalPriceMWh;      // encrypted system marginal price
        euint64 imbalancePenalty;      // encrypted penalty for deviations
        bool settled;
    }

    struct GeneratorBid {
        address generator;
        euint64 offeredMW;             // encrypted capacity offered
        euint64 bidPriceMWh;           // encrypted offer price
        euint64 minimumLoadMW;         // encrypted must-run minimum
        euint64 dispatchedMW;          // encrypted amount dispatched
        bool submitted;
    }

    mapping(uint256 => DispatchInterval) private intervals;
    mapping(uint256 => mapping(address => GeneratorBid)) private generatorBids;
    mapping(address => euint64) private _generatorRevenue;
    mapping(address => bool) public isGenerator;
    mapping(address => bool) public isGridOperator;
    uint256 public intervalCount;
    euint64 private _totalGridRevenue;

    event IntervalCreated(uint256 indexed id, uint256 start);
    event BidSubmitted(uint256 indexed intervalId, address generator);
    event IntervalDispatched(uint256 indexed intervalId);
    event IntervalSettled(uint256 indexed intervalId);

    modifier onlyGridOperator() {
        require(isGridOperator[msg.sender] || msg.sender == owner(), "Not grid operator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalGridRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalGridRevenue);
        isGridOperator[msg.sender] = true;
    }

    function addGenerator(address g) external onlyOwner { isGenerator[g] = true; }
    function addGridOperator(address go) external onlyOwner { isGridOperator[go] = true; }

    function createInterval(
        BalancingInterval duration,
        externalEuint64 encTargetLoad, bytes calldata tlProof,
        externalEuint64 encImbalancePenalty, bytes calldata ipProof
    ) external onlyGridOperator returns (uint256 id) {
        euint64 targetLoad = FHE.fromExternal(encTargetLoad, tlProof);
        euint64 imbalancePenalty = FHE.fromExternal(encImbalancePenalty, ipProof);
        id = intervalCount++;
        intervals[id] = DispatchInterval({
            intervalStart: block.timestamp, duration: duration,
            targetLoadMW: targetLoad, totalOfferedMW: FHE.asEuint64(0),
            marginalPriceMWh: FHE.asEuint64(0), imbalancePenalty: imbalancePenalty, settled: false
        });
        FHE.allowThis(intervals[id].targetLoadMW);
        FHE.allowThis(intervals[id].totalOfferedMW);
        FHE.allowThis(intervals[id].marginalPriceMWh);
        FHE.allowThis(intervals[id].imbalancePenalty);
        emit IntervalCreated(id, block.timestamp);
    }

    function submitBid(
        uint256 intervalId,
        externalEuint64 encOfferedMW, bytes calldata omProof,
        externalEuint64 encBidPrice, bytes calldata bpProof,
        externalEuint64 encMinLoad, bytes calldata mlProof
    ) external {
        require(isGenerator[msg.sender], "Not generator");
        DispatchInterval storage di = intervals[intervalId];
        require(!di.settled, "Already settled");
        euint64 offeredMW = FHE.fromExternal(encOfferedMW, omProof);
        euint64 bidPrice = FHE.fromExternal(encBidPrice, bpProof);
        euint64 minLoad = FHE.fromExternal(encMinLoad, mlProof);
        generatorBids[intervalId][msg.sender] = GeneratorBid({
            generator: msg.sender, offeredMW: offeredMW, bidPriceMWh: bidPrice,
            minimumLoadMW: minLoad, dispatchedMW: FHE.asEuint64(0), submitted: true
        });
        di.totalOfferedMW = FHE.add(di.totalOfferedMW, offeredMW);
        FHE.allowThis(generatorBids[intervalId][msg.sender].offeredMW);
        FHE.allow(generatorBids[intervalId][msg.sender].offeredMW, msg.sender);
        FHE.allowThis(generatorBids[intervalId][msg.sender].bidPriceMWh);
        FHE.allow(generatorBids[intervalId][msg.sender].bidPriceMWh, msg.sender);
        FHE.allowThis(generatorBids[intervalId][msg.sender].minimumLoadMW);
        FHE.allowThis(generatorBids[intervalId][msg.sender].dispatchedMW);
        FHE.allowThis(di.totalOfferedMW);
        if (!FHE.isInitialized(_generatorRevenue[msg.sender])) {
            _generatorRevenue[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_generatorRevenue[msg.sender]);
        }
        emit BidSubmitted(intervalId, msg.sender);
    }

    function dispatchInterval(
        uint256 intervalId, address[] calldata generators,
        externalEuint64 encMarginalPrice, bytes calldata mpProof
    ) external onlyGridOperator {
        DispatchInterval storage di = intervals[intervalId];
        euint64 marginalPrice = FHE.fromExternal(encMarginalPrice, mpProof);
        di.marginalPriceMWh = marginalPrice;
        FHE.allowThis(di.marginalPriceMWh);
        // Dispatch generators at/below marginal price
        for (uint256 i = 0; i < generators.length; i++) {
            GeneratorBid storage bid = generatorBids[intervalId][generators[i]];
            if (!bid.submitted) continue;
            ebool dispatched = FHE.le(bid.bidPriceMWh, marginalPrice);
            bid.dispatchedMW = FHE.select(dispatched, bid.offeredMW, bid.minimumLoadMW);
            ebool _safeMul57 = FHE.le(bid.dispatchedMW, FHE.asEuint64(type(uint32).max));
            euint64 revenue = FHE.mul(bid.dispatchedMW, marginalPrice);
            _generatorRevenue[generators[i]] = FHE.add(_generatorRevenue[generators[i]], revenue);
            _totalGridRevenue = FHE.add(_totalGridRevenue, revenue);
            FHE.allowThis(bid.dispatchedMW);
            FHE.allow(bid.dispatchedMW, generators[i]);
            FHE.allowThis(_generatorRevenue[generators[i]]);
            FHE.allow(_generatorRevenue[generators[i]], generators[i]);
            FHE.allowThis(_totalGridRevenue);
        }
        emit IntervalDispatched(intervalId);
    }

    function settleInterval(uint256 intervalId) external onlyGridOperator {
        intervals[intervalId].settled = true;
        emit IntervalSettled(intervalId);
    }

    function allowIntervalDetails(uint256 id, address viewer) external onlyGridOperator {
        FHE.allow(intervals[id].targetLoadMW, viewer);
        FHE.allow(intervals[id].marginalPriceMWh, viewer);
        FHE.allow(intervals[id].totalOfferedMW, viewer);
    }
}
