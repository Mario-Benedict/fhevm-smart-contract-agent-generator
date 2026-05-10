// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOceanFreightRateDerivative
/// @notice Encrypted Baltic Dry Index-linked freight rate derivative.
///         Shipping companies hedge encrypted freight rate exposure.
///         Settlement is based on encrypted index readings.
contract PrivateOceanFreightRateDerivative is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RouteIndex { Capesize, Panamax, Supramax, Handysize, VLCC, Aframax }
    enum DerivativeType { Swap, Cap, Floor, Collar }
    enum ContractStatus { Active, Settled, Expired, Defaulted }

    struct FreightDerivative {
        address shipowner;
        address counterparty;
        RouteIndex routeIndex;
        DerivativeType derivType;
        euint64 notionalTonnes;         // encrypted cargo tonnage
        euint32 strikeRateUSDPerTonne;  // encrypted agreed freight rate
        euint32 currentIndexRate;       // encrypted current BDI rate
        euint64 settlementAmount;       // encrypted P&L at settlement
        euint32 marginPostedBps;        // encrypted initial margin
        euint64 markToMarketUSD;        // encrypted current MTM
        ContractStatus status;
        uint256 tradeDate;
        uint256 settlementDate;
    }

    struct IndexFixing {
        RouteIndex routeIndex;
        euint32 fixedRate;              // encrypted daily index rate
        uint256 fixingDate;
        address fixingAgent;
    }

    mapping(uint256 => FreightDerivative) private derivatives;
    mapping(uint256 => IndexFixing[]) private indexHistory;
    mapping(address => bool) public isShipowner;
    mapping(address => bool) public isFixingAgent;
    mapping(address => bool) public isBroker;

    uint256 public derivativeCount;
    euint64 private _totalOpenNotional;
    euint64 private _totalSettledPnL;

    event DerivativeCreated(uint256 indexed id, address shipowner, RouteIndex routeIndex);
    event IndexFixed(RouteIndex routeIndex, uint256 fixingDate);
    event DerivativeSettled(uint256 indexed id);
    event MarginCall(uint256 indexed id, address party);

    modifier onlyFixingAgent() {
        require(isFixingAgent[msg.sender] || msg.sender == owner(), "Not fixing agent");
        _;
    }

    modifier onlyBroker() {
        require(isBroker[msg.sender] || msg.sender == owner(), "Not broker");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOpenNotional = FHE.asEuint64(0);
        _totalSettledPnL = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenNotional);
        FHE.allowThis(_totalSettledPnL);
        isFixingAgent[msg.sender] = true;
        isBroker[msg.sender] = true;
    }

    function addFixingAgent(address fa) external onlyOwner { isFixingAgent[fa] = true; }
    function addBroker(address b) external onlyOwner { isBroker[b] = true; }
    function registerShipowner(address so) external onlyOwner { isShipowner[so] = true; }

    function createDerivative(
        address counterparty,
        RouteIndex routeIndex,
        DerivativeType derivType,
        externalEuint64 encNotional, bytes calldata notProof,
        externalEuint32 encStrikeRate, bytes calldata strikeProof,
        externalEuint32 encMarginBps, bytes calldata marginProof,
        uint256 settlementDate
    ) external onlyBroker returns (uint256 derivId) {
        euint64 notional = FHE.fromExternal(encNotional, notProof);
        euint64 notionalWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 notionalExposure = FHE.sub(notionalWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint32 strikeRate = FHE.fromExternal(encStrikeRate, strikeProof);
        euint32 marginBps = FHE.fromExternal(encMarginBps, marginProof);

        derivId = derivativeCount++;
        FreightDerivative storage d = derivatives[derivId];
        d.shipowner = msg.sender;
        d.counterparty = counterparty;
        d.routeIndex = routeIndex;
        d.derivType = derivType;
        d.notionalTonnes = notional;
        d.strikeRateUSDPerTonne = strikeRate;
        d.currentIndexRate = FHE.asEuint32(0);
        d.settlementAmount = FHE.asEuint64(0);
        d.marginPostedBps = marginBps;
        d.markToMarketUSD = FHE.asEuint64(0);
        d.status = ContractStatus.Active;
        d.tradeDate = block.timestamp;
        d.settlementDate = settlementDate;

        _totalOpenNotional = FHE.add(_totalOpenNotional, notional);

        FHE.allowThis(d.notionalTonnes); FHE.allow(d.notionalTonnes, msg.sender); FHE.allow(d.notionalTonnes, counterparty);
        FHE.allowThis(d.strikeRateUSDPerTonne); FHE.allow(d.strikeRateUSDPerTonne, msg.sender);
        FHE.allowThis(d.currentIndexRate); FHE.allow(d.currentIndexRate, msg.sender);
        FHE.allowThis(d.settlementAmount);
        FHE.allowThis(d.marginPostedBps); FHE.allow(d.marginPostedBps, msg.sender);
        FHE.allowThis(d.markToMarketUSD); FHE.allow(d.markToMarketUSD, msg.sender); FHE.allow(d.markToMarketUSD, counterparty);
        FHE.allowThis(_totalOpenNotional);

        emit DerivativeCreated(derivId, msg.sender, routeIndex);
    }

    function publishIndexFixing(
        RouteIndex routeIndex,
        externalEuint32 encRate, bytes calldata proof
    ) external onlyFixingAgent {
        euint32 rate = FHE.fromExternal(encRate, proof);
        uint256 idx = indexHistory[uint256(routeIndex)].length;
        indexHistory[uint256(routeIndex)].push(IndexFixing({
            routeIndex: routeIndex,
            fixedRate: rate,
            fixingDate: block.timestamp,
            fixingAgent: msg.sender
        }));
        FHE.allowThis(indexHistory[uint256(routeIndex)][idx].fixedRate);
        emit IndexFixed(routeIndex, block.timestamp);
    }

    function updateMarkToMarket(
        uint256 derivId,
        externalEuint32 encCurrentRate, bytes calldata rateProof
    ) external onlyFixingAgent {
        FreightDerivative storage d = derivatives[derivId];
        require(d.status == ContractStatus.Active, "Not active");
        euint32 currentRate = FHE.fromExternal(encCurrentRate, rateProof);
        d.currentIndexRate = currentRate;
        // MTM = notional * (currentRate - strikeRate) for payer swap
        ebool positive = FHE.ge(currentRate, d.strikeRateUSDPerTonne);
        euint32 rateDiff = FHE.select(positive,
            FHE.sub(currentRate, d.strikeRateUSDPerTonne),
            FHE.sub(d.strikeRateUSDPerTonne, currentRate)
        );
        d.markToMarketUSD = FHE.mul(d.notionalTonnes, FHE.asEuint64(rateDiff));
        FHE.allowThis(d.currentIndexRate);
        FHE.allowThis(d.markToMarketUSD); FHE.allow(d.markToMarketUSD, d.shipowner); FHE.allow(d.markToMarketUSD, d.counterparty);
    }

    function settleDerivative(
        uint256 derivId,
        externalEuint64 encSettlement, bytes calldata proof
    ) external onlyBroker nonReentrant {
        FreightDerivative storage d = derivatives[derivId];
        require(d.status == ContractStatus.Active, "Not active");
        require(block.timestamp >= d.settlementDate, "Too early");
        euint64 settlement = FHE.fromExternal(encSettlement, proof);
        d.settlementAmount = settlement;
        d.status = ContractStatus.Settled;
        _totalOpenNotional = FHE.sub(_totalOpenNotional, d.notionalTonnes);
        _totalSettledPnL = FHE.add(_totalSettledPnL, settlement);
        FHE.allowThis(d.settlementAmount); FHE.allow(d.settlementAmount, d.shipowner); FHE.allow(d.settlementAmount, d.counterparty);
        FHE.allowThis(_totalOpenNotional); FHE.allowThis(_totalSettledPnL);
        emit DerivativeSettled(derivId);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalOpenNotional, viewer); // [acl_misconfig]
        FHE.allow(_totalOpenNotional, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSettledPnL, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSettledPnL, viewer);
    }
}
