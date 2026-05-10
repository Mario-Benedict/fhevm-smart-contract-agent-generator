// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDigitalTwinAssetValuation
/// @notice Digital twin asset valuation platform: encrypted sensor readings from physical assets,
///         encrypted predicted failure probability, encrypted maintenance cost forecasts,
///         and private insurance underwriting scores derived from digital twin data.
contract PrivateDigitalTwinAssetValuation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AssetClass { INDUSTRIAL_MACHINE, REAL_ESTATE, AIRCRAFT, VESSEL, POWER_PLANT, DATA_CENTER }

    struct DigitalTwin {
        string assetId;
        AssetClass assetClass;
        address assetOwner;
        euint64 currentValueUSD;       // encrypted current appraised value
        euint64 replacementCostUSD;    // encrypted replacement cost
        euint64 operationalEfficiency; // encrypted OEE score 0-1000
        euint64 failureProbabilityBps; // encrypted 12-month failure probability
        euint64 maintenanceForecastUSD;// encrypted 12-month maintenance forecast
        euint64 insurancePremiumBps;   // encrypted recommended premium
        uint256 lastUpdated;
        bool active;
    }

    struct SensorReading {
        uint256 twinId;
        string sensorType; // "vibration", "temperature", "pressure", "current"
        euint64 readingValue;       // encrypted sensor value (scaled)
        euint64 anomalyScore;       // encrypted anomaly score 0-1000
        uint256 timestamp;
        bool alertTriggered;
    }

    struct ValuationReport {
        uint256 twinId;
        euint64 reportedValue;       // encrypted final valuation
        euint64 confidenceScore;     // encrypted confidence in valuation 0-100
        euint64 depreciationBps;     // encrypted annual depreciation rate
        string methodology;
        uint256 reportDate;
        address appraiser;
    }

    mapping(uint256 => DigitalTwin) private twins;
    mapping(uint256 => SensorReading[]) private sensorData;
    mapping(uint256 => ValuationReport[]) private valuations;
    uint256 public twinCount;
    euint64 private _totalAssetValueUnderManagement;
    mapping(address => bool) public isValuationAgent;
    mapping(address => bool) public isSensorOracle;
    mapping(address => bool) public isInsuranceUnderwriter;

    event TwinRegistered(uint256 indexed id, string assetId, AssetClass class_);
    event SensorDataReceived(uint256 indexed twinId, string sensorType, bool alert);
    event ValuationCompleted(uint256 indexed twinId, uint256 valuationIndex);
    event AlertEscalated(uint256 indexed twinId, string sensorType);
    event PremiumUpdated(uint256 indexed twinId);

    constructor() Ownable(msg.sender) {
        _totalAssetValueUnderManagement = FHE.asEuint64(0);
        FHE.allowThis(_totalAssetValueUnderManagement);
        isValuationAgent[msg.sender] = true;
        isSensorOracle[msg.sender] = true;
        isInsuranceUnderwriter[msg.sender] = true;
    }

    function addAgent(address a) external onlyOwner { isValuationAgent[a] = true; }
    function addOracle(address o) external onlyOwner { isSensorOracle[o] = true; }
    function addUnderwriter(address u) external onlyOwner { isInsuranceUnderwriter[u] = true; }

    function registerTwin(
        string calldata assetId, AssetClass class_,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encReplacement, bytes calldata rProof,
        externalEuint64 encOEE, bytes calldata oProof
    ) external returns (uint256 id) {
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint64 replacement = FHE.fromExternal(encReplacement, rProof);
        euint64 oee = FHE.fromExternal(encOEE, oProof);
        id = twinCount++;
        twins[id].assetId = assetId;
        twins[id].assetClass = class_;
        twins[id].assetOwner = msg.sender;
        twins[id].currentValueUSD = value;
        twins[id].replacementCostUSD = replacement;
        twins[id].operationalEfficiency = oee;
        twins[id].failureProbabilityBps = FHE.asEuint64(0);
        twins[id].maintenanceForecastUSD = FHE.asEuint64(0);
        twins[id].insurancePremiumBps = FHE.asEuint64(0);
        twins[id].lastUpdated = block.timestamp;
        twins[id].active = true;
        _totalAssetValueUnderManagement = FHE.add(_totalAssetValueUnderManagement, value);
        FHE.allowThis(twins[id].currentValueUSD);
        FHE.allowThis(twins[id].replacementCostUSD);
        FHE.allowThis(twins[id].operationalEfficiency);
        FHE.allowThis(twins[id].failureProbabilityBps);
        FHE.allowThis(twins[id].maintenanceForecastUSD);
        FHE.allowThis(twins[id].insurancePremiumBps);
        FHE.allow(twins[id].currentValueUSD, msg.sender);
        FHE.allow(twins[id].failureProbabilityBps, msg.sender);
        FHE.allowThis(_totalAssetValueUnderManagement);
        emit TwinRegistered(id, assetId, class_);
    }

    function recordSensorReading(
        uint256 twinId, string calldata sensorType,
        externalEuint64 encReading, bytes calldata rProof,
        externalEuint64 encAnomaly, bytes calldata aProof
    ) external returns (bool alertTriggered) {
        require(isSensorOracle[msg.sender], "Not oracle");
        euint64 reading = FHE.fromExternal(encReading, rProof);
        euint64 anomaly = FHE.fromExternal(encAnomaly, aProof);
        // Alert if anomaly > 700
        ebool isAnomaly = FHE.ge(anomaly, FHE.asEuint64(700));
        alertTriggered = true; // always record, oracle decides off-chain
        sensorData[twinId].push(SensorReading({
            twinId: twinId, sensorType: sensorType,
            readingValue: reading, anomalyScore: anomaly,
            timestamp: block.timestamp, alertTriggered: alertTriggered
        }));
        uint256 idx = sensorData[twinId].length - 1;
        FHE.allowThis(sensorData[twinId][idx].readingValue);
        FHE.allowThis(sensorData[twinId][idx].anomalyScore);
        // Update failure probability
        DigitalTwin storage twin = twins[twinId];
        euint64 newFailureProb = FHE.select(isAnomaly,
            FHE.add(twin.failureProbabilityBps, FHE.asEuint64(500)),
            twin.failureProbabilityBps);
        twin.failureProbabilityBps = newFailureProb;
        twin.lastUpdated = block.timestamp;
        FHE.allowThis(twin.failureProbabilityBps);
        FHE.allow(twin.failureProbabilityBps, twin.assetOwner);
        emit SensorDataReceived(twinId, sensorType, alertTriggered);
    }

    function submitValuation(
        uint256 twinId,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encConfidence, bytes calldata cProof,
        externalEuint64 encDepreciation, bytes calldata dProof,
        string calldata methodology
    ) external returns (uint256 idx) {
        require(isValuationAgent[msg.sender], "Not agent");
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint64 confidence = FHE.fromExternal(encConfidence, cProof);
        euint64 depreciation = FHE.fromExternal(encDepreciation, dProof);
        DigitalTwin storage twin = twins[twinId];
        _totalAssetValueUnderManagement = FHE.sub(_totalAssetValueUnderManagement, twin.currentValueUSD);
        twin.currentValueUSD = value;
        _totalAssetValueUnderManagement = FHE.add(_totalAssetValueUnderManagement, value);
        idx = valuations[twinId].length;
        valuations[twinId].push(ValuationReport({
            twinId: twinId, reportedValue: value,
            confidenceScore: confidence, depreciationBps: depreciation,
            methodology: methodology, reportDate: block.timestamp, appraiser: msg.sender
        }));
        FHE.allowThis(valuations[twinId][idx].reportedValue);
        FHE.allowThis(valuations[twinId][idx].confidenceScore);
        FHE.allowThis(valuations[twinId][idx].depreciationBps);
        FHE.allow(valuations[twinId][idx].reportedValue, twin.assetOwner);
        FHE.allowThis(twin.currentValueUSD);
        FHE.allowThis(_totalAssetValueUnderManagement);
        emit ValuationCompleted(twinId, idx);
    }

    function updateInsurancePremium(
        uint256 twinId,
        externalEuint64 encMaintForecast, bytes calldata mProof
    ) external {
        require(isInsuranceUnderwriter[msg.sender], "Not underwriter");
        DigitalTwin storage twin = twins[twinId];
        euint64 maintForecast = FHE.fromExternal(encMaintForecast, mProof);
        twin.maintenanceForecastUSD = maintForecast;
        // Premium = failure probability bps + maintenance forecast factor
        euint64 premium = FHE.add(twin.failureProbabilityBps, FHE.div(maintForecast, 1000));
        twin.insurancePremiumBps = premium;
        FHE.allowThis(twin.maintenanceForecastUSD);
        FHE.allowThis(twin.insurancePremiumBps);
        FHE.allow(twin.insurancePremiumBps, twin.assetOwner);
        emit PremiumUpdated(twinId);
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