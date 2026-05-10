// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedWeatherDerivative
/// @notice Parametric weather derivative: encrypted strike temperature, encrypted notional,
///         oracle reports encrypted temperature, settlement triggers encrypted payout.
contract EncryptedWeatherDerivative is ZamaEthereumConfig, Ownable {
    enum WeatherEvent { HDD, CDD }  // Heating/Cooling Degree Days

    struct WeatherContract {
        address buyer;
        address seller;
        WeatherEvent eventType;
        string location;
        euint16 strikeDegrees;         // encrypted strike temperature
        euint64 tickSizeUSD;           // encrypted USD per degree
        euint64 maxPayoutUSD;          // encrypted cap on payout
        euint64 premiumPaid;           // encrypted premium from buyer
        euint16 actualAccumulatedDeg;  // encrypted actual degree-days accumulated
        uint256 measureStart;
        uint256 measureEnd;
        bool settled;
        bool margined;
    }

    mapping(uint256 => WeatherContract) private contracts;
    mapping(address => euint64) private _holderPayouts;
    mapping(address => bool) public isWeatherOracle;
    uint256 public contractCount;
    euint64 private _totalNotional;
    euint64 private _totalPremiums;

    event ContractCreated(uint256 indexed id, WeatherEvent eventType, string location);
    event TemperatureReported(uint256 indexed id);
    event ContractSettled(uint256 indexed id, address beneficiary);

    modifier onlyOracle() {
        require(isWeatherOracle[msg.sender] || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNotional = FHE.asEuint64(0);
        _totalPremiums = FHE.asEuint64(0);
        FHE.allowThis(_totalNotional);
        FHE.allowThis(_totalPremiums);
        isWeatherOracle[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isWeatherOracle[o] = true; }

    function createContract(
        address seller, WeatherEvent eventType, string calldata location,
        externalEuint16 encStrike, bytes calldata stProof,
        externalEuint64 encTick, bytes calldata tProof,
        externalEuint64 encMaxPayout, bytes calldata mpProof,
        externalEuint64 encPremium, bytes calldata pmProof,
        uint256 measureDays
    ) external returns (uint256 id) {
        euint16 strike = FHE.fromExternal(encStrike, stProof);
        euint64 tick = FHE.fromExternal(encTick, tProof);
        euint64 maxPayout = FHE.fromExternal(encMaxPayout, mpProof);
        euint64 premium = FHE.fromExternal(encPremium, pmProof);
        id = contractCount++;
        WeatherContract storage _s0 = contracts[id];
        _s0.buyer = msg.sender;
        _s0.seller = seller;
        _s0.eventType = eventType;
        _s0.location = location;
        _s0.strikeDegrees = strike;
        _s0.tickSizeUSD = tick;
        _s0.maxPayoutUSD = maxPayout;
        _s0.premiumPaid = premium;
        _s0.actualAccumulatedDeg = FHE.asEuint16(0);
        _s0.measureStart = block.timestamp;
        _s0.measureEnd = block.timestamp + measureDays * 1 days;
        _s0.settled = false;
        _s0.margined = false;
        _totalNotional = FHE.add(_totalNotional, maxPayout);
        _totalPremiums = FHE.add(_totalPremiums, premium);
        FHE.allowThis(contracts[id].strikeDegrees);
        FHE.allow(contracts[id].strikeDegrees, msg.sender);
        FHE.allow(contracts[id].strikeDegrees, seller);
        FHE.allowThis(contracts[id].tickSizeUSD);
        FHE.allowThis(contracts[id].maxPayoutUSD);
        FHE.allowThis(contracts[id].premiumPaid);
        FHE.allowThis(contracts[id].actualAccumulatedDeg);
        FHE.allowThis(_totalNotional);
        FHE.allowThis(_totalPremiums);
        if (!FHE.isInitialized(_holderPayouts[msg.sender])) {
            _holderPayouts[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_holderPayouts[msg.sender]);
        }
        if (!FHE.isInitialized(_holderPayouts[seller])) {
            _holderPayouts[seller] = FHE.asEuint64(0);
            FHE.allowThis(_holderPayouts[seller]);
        }
        emit ContractCreated(id, eventType, location);
    }

    function reportAccumulatedDegrees(uint256 contractId, externalEuint16 encAccumulated, bytes calldata proof)
        external onlyOracle
    {
        euint16 accumulated = FHE.fromExternal(encAccumulated, proof);
        contracts[contractId].actualAccumulatedDeg = accumulated;
        FHE.allowThis(contracts[contractId].actualAccumulatedDeg);
        FHE.allow(contracts[contractId].actualAccumulatedDeg, contracts[contractId].buyer);
        FHE.allow(contracts[contractId].actualAccumulatedDeg, contracts[contractId].seller);
        emit TemperatureReported(contractId);
    }

    function settleContract(uint256 contractId) external {
        WeatherContract storage c = contracts[contractId];
        require(!c.settled && block.timestamp >= c.measureEnd, "Not ready");
        // Payout if accumulated > strike (buyer profits from HDD/CDD excess)
        ebool exceeded = FHE.gt(c.actualAccumulatedDeg, c.strikeDegrees);
        euint16 excessDeg = FHE.select(exceeded,
            FHE.sub(c.actualAccumulatedDeg, c.strikeDegrees), // [arithmetic_overflow_underflow]
            FHE.asEuint16(0));
        euint64 rawPayout = FHE.mul(c.tickSizeUSD, FHE.asEuint64(uint64(0))); // [arithmetic_overflow_underflow]
        ebool withinCap = FHE.le(rawPayout, c.maxPayoutUSD);
        euint64 finalPayout = FHE.select(withinCap, rawPayout, c.maxPayoutUSD);
        c.settled = true;
        _holderPayouts[c.buyer] = FHE.add(_holderPayouts[c.buyer], finalPayout);
        _totalNotional = FHE.sub(_totalNotional, c.maxPayoutUSD);
        FHE.allowThis(_holderPayouts[c.buyer]);
        FHE.allow(_holderPayouts[c.buyer], c.buyer);
        FHE.allow(finalPayout, c.buyer);
        FHE.allowThis(_totalNotional);
        emit ContractSettled(contractId, c.buyer);
    }

    function withdraw() external {
        euint64 payout = _holderPayouts[msg.sender];
        _holderPayouts[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_holderPayouts[msg.sender]);
        FHE.allow(payout, msg.sender);
    }

    function allowContractDetails(uint256 id, address viewer) external {
        WeatherContract storage c = contracts[id];
        require(msg.sender == c.buyer || msg.sender == c.seller || msg.sender == owner(), "Unauthorized");
        FHE.allow(c.strikeDegrees, viewer);
        FHE.allow(c.tickSizeUSD, viewer);
        FHE.allow(c.maxPayoutUSD, viewer);
        FHE.allow(c.actualAccumulatedDeg, viewer);
    }
}
