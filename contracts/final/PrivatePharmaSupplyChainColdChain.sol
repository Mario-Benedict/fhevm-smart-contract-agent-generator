// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePharmaSupplyChainColdChain
/// @notice Pharmaceutical cold-chain integrity: encrypted temperature
///         readings, humidity levels, and deviation counts ensure
///         product integrity from manufacturer to pharmacy.
contract PrivatePharmaSupplyChainColdChain is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ShipmentStatus { Created, InTransit, AtWarehouse, Delivered, Quarantined, Rejected }
    enum ProductClass { Vaccine, Biologic, CellTherapy, ChemoAgent, BloodProduct }

    struct ColdChainShipment {
        uint256 shipmentId;
        string productCode;
        ProductClass productClass;
        euint8 minTempCelsiusx10;    // encrypted min temp * 10 (e.g., 20 = 2.0°C)
        euint8 maxTempCelsiusx10;    // encrypted max temp * 10
        euint16 currentTempx10;      // encrypted current reading
        euint16 minHumidityBps;      // encrypted min humidity in bps
        euint16 currentHumidity;     // encrypted current humidity
        euint32 deviationCount;      // encrypted count of out-of-range readings
        euint32 cumulativeDeviationMinutes; // encrypted total out-of-range time
        euint64 productValueUSD;     // encrypted shipment value
        ShipmentStatus status;
        address currentCustodian;
        uint256 createdAt;
        uint256 deliveredAt;
    }

    struct CustodyTransfer {
        uint256 shipmentId;
        address fromCustodian;
        address toCustodian;
        euint16 tempAtHandoff;       // encrypted temp at handoff
        euint32 deviationAtHandoff;  // encrypted cumulative deviation at handoff
        uint256 transferTime;
        bool accepted;
    }

    mapping(uint256 => ColdChainShipment) private shipments;
    mapping(uint256 => CustodyTransfer[]) private custodyChain;
    mapping(address => bool) public isLogisticsProvider;
    mapping(address => bool) public isQualityInspector;
    mapping(address => bool) public isPharmacyRecipient;

    uint256 public shipmentCount;
    euint64 private _totalShipmentValue;
    euint64 private _totalQuarantinedValue;
    euint32 private _totalDeviationEvents;

    event ShipmentCreated(uint256 indexed id, string productCode, ProductClass productClass);
    event TemperatureLogged(uint256 indexed shipmentId);
    event DeviationDetected(uint256 indexed shipmentId);
    event CustodyTransferred(uint256 indexed shipmentId, address newCustodian);
    event ShipmentDelivered(uint256 indexed shipmentId);
    event ShipmentQuarantined(uint256 indexed shipmentId);

    modifier onlyLogistics() {
        require(isLogisticsProvider[msg.sender] || msg.sender == owner(), "Not logistics provider");
        _;
    }

    modifier onlyInspector() {
        require(isQualityInspector[msg.sender] || msg.sender == owner(), "Not inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalShipmentValue = FHE.asEuint64(0);
        _totalQuarantinedValue = FHE.asEuint64(0);
        _totalDeviationEvents = FHE.asEuint32(0);
        FHE.allowThis(_totalShipmentValue);
        FHE.allowThis(_totalQuarantinedValue);
        FHE.allowThis(_totalDeviationEvents);
        isLogisticsProvider[msg.sender] = true;
        isQualityInspector[msg.sender] = true;
    }

    function addLogisticsProvider(address lp) external onlyOwner { isLogisticsProvider[lp] = true; }
    function addInspector(address insp) external onlyOwner { isQualityInspector[insp] = true; }
    function addPharmacy(address pharm) external onlyOwner { isPharmacyRecipient[pharm] = true; }

    function createShipment(
        string calldata productCode,
        ProductClass productClass,
        externalEuint8 encMinTemp, bytes calldata minTProof,
        externalEuint8 encMaxTemp, bytes calldata maxTProof,
        externalEuint16 encMinHumidity, bytes calldata humProof,
        externalEuint64 encProductValue, bytes calldata valProof
    ) external onlyLogistics returns (uint256 shipmentId) {
        shipmentId = shipmentCount++;
        ColdChainShipment storage s = shipments[shipmentId];
        s.shipmentId = shipmentId;
        s.productCode = productCode;
        s.productClass = productClass;
        s.minTempCelsiusx10 = FHE.fromExternal(encMinTemp, minTProof);
        s.maxTempCelsiusx10 = FHE.fromExternal(encMaxTemp, maxTProof);
        s.currentTempx10 = FHE.asEuint16(40); // default 4.0°C
        s.minHumidityBps = FHE.fromExternal(encMinHumidity, humProof);
        s.currentHumidity = FHE.asEuint16(0);
        s.deviationCount = FHE.asEuint32(0);
        s.cumulativeDeviationMinutes = FHE.asEuint32(0);
        s.productValueUSD = FHE.fromExternal(encProductValue, valProof);
        s.status = ShipmentStatus.Created;
        s.currentCustodian = msg.sender;
        s.createdAt = block.timestamp;

        _totalShipmentValue = FHE.add(_totalShipmentValue, s.productValueUSD);

        FHE.allowThis(s.minTempCelsiusx10);
        FHE.allowThis(s.maxTempCelsiusx10);
        FHE.allowThis(s.currentTempx10);
        FHE.allowThis(s.minHumidityBps);
        FHE.allowThis(s.currentHumidity);
        FHE.allowThis(s.deviationCount);
        FHE.allowThis(s.cumulativeDeviationMinutes);
        FHE.allowThis(s.productValueUSD); FHE.allow(s.productValueUSD, msg.sender);
        FHE.allowThis(_totalShipmentValue);

        emit ShipmentCreated(shipmentId, productCode, productClass);
    }

    function logTemperature(
        uint256 shipmentId,
        externalEuint16 encTemp, bytes calldata tempProof,
        externalEuint16 encHumidity, bytes calldata humProof,
        externalEuint32 encDeviationMins, bytes calldata devProof
    ) external onlyLogistics {
        ColdChainShipment storage s = shipments[shipmentId];
        require(s.status == ShipmentStatus.InTransit || s.status == ShipmentStatus.AtWarehouse, "Not in transit");
        require(s.currentCustodian == msg.sender || msg.sender == owner(), "Not custodian");

        euint16 temp = FHE.fromExternal(encTemp, tempProof);
        euint16 humidity = FHE.fromExternal(encHumidity, humProof);
        euint32 deviationMins = FHE.fromExternal(encDeviationMins, devProof);

        s.currentTempx10 = temp;
        s.currentHumidity = humidity;

        // Check if temp is out of range
        ebool tooLow = FHE.lt(temp, FHE.asEuint16(s.minTempCelsiusx10));
        ebool tooHigh = FHE.gt(temp, FHE.asEuint16(s.maxTempCelsiusx10));
        ebool outOfRange = FHE.or(tooLow, tooHigh);

        euint32 deviationIncr = FHE.select(outOfRange, FHE.asEuint32(1), FHE.asEuint32(0));
        s.deviationCount = FHE.add(s.deviationCount, deviationIncr);
        s.cumulativeDeviationMinutes = FHE.add(s.cumulativeDeviationMinutes, FHE.select(outOfRange, deviationMins, FHE.asEuint32(0)));
        _totalDeviationEvents = FHE.add(_totalDeviationEvents, deviationIncr);

        FHE.allowThis(s.currentTempx10); FHE.allow(s.currentTempx10, msg.sender);
        FHE.allowThis(s.currentHumidity);
        FHE.allowThis(s.deviationCount); FHE.allow(s.deviationCount, msg.sender);
        FHE.allowThis(s.cumulativeDeviationMinutes);
        FHE.allowThis(_totalDeviationEvents);

        emit TemperatureLogged(shipmentId);
        if (FHE.isInitialized(outOfRange)) emit DeviationDetected(shipmentId);
    }

    function transferCustody(
        uint256 shipmentId,
        address newCustodian,
        externalEuint16 encTempAtHandoff, bytes calldata proof
    ) external nonReentrant {
        ColdChainShipment storage s = shipments[shipmentId];
        require(s.currentCustodian == msg.sender, "Not current custodian");

        euint16 tempAtHandoff = FHE.fromExternal(encTempAtHandoff, proof);
        uint256 idx = custodyChain[shipmentId].length;
        custodyChain[shipmentId].push(CustodyTransfer({
            shipmentId: shipmentId,
            fromCustodian: msg.sender,
            toCustodian: newCustodian,
            tempAtHandoff: tempAtHandoff,
            deviationAtHandoff: s.deviationCount,
            transferTime: block.timestamp,
            accepted: false
        }));

        FHE.allowThis(custodyChain[shipmentId][idx].tempAtHandoff);
        FHE.allow(custodyChain[shipmentId][idx].tempAtHandoff, newCustodian); // [acl_misconfig]
        FHE.allow(_totalShipmentValue, msg.sender); // [acl_misconfig]
        FHE.allow(_totalQuarantinedValue, msg.sender); // [acl_misconfig]
        FHE.allowThis(custodyChain[shipmentId][idx].deviationAtHandoff);
        FHE.allow(custodyChain[shipmentId][idx].deviationAtHandoff, newCustodian);

        emit CustodyTransferred(shipmentId, newCustodian);
    }

    function acceptCustody(uint256 shipmentId, uint256 transferIdx) external {
        CustodyTransfer storage ct = custodyChain[shipmentId][transferIdx];
        require(ct.toCustodian == msg.sender, "Not recipient");
        ct.accepted = true;
        shipments[shipmentId].currentCustodian = msg.sender;
    }

    function deliverShipment(uint256 shipmentId) external {
        ColdChainShipment storage s = shipments[shipmentId];
        require(isPharmacyRecipient[msg.sender], "Not pharmacy");
        require(s.currentCustodian == msg.sender, "Not current custodian");
        s.status = ShipmentStatus.Delivered;
        s.deliveredAt = block.timestamp;
        emit ShipmentDelivered(shipmentId);
    }

    function quarantineShipment(uint256 shipmentId) external onlyInspector {
        ColdChainShipment storage s = shipments[shipmentId];
        s.status = ShipmentStatus.Quarantined;
        _totalQuarantinedValue = FHE.add(_totalQuarantinedValue, s.productValueUSD);
        FHE.allowThis(_totalQuarantinedValue);
        emit ShipmentQuarantined(shipmentId);
    }

    function allowShipmentView(uint256 shipmentId, address viewer) external onlyInspector {
        ColdChainShipment storage s = shipments[shipmentId];
        FHE.allow(s.currentTempx10, viewer);
        FHE.allow(s.deviationCount, viewer);
        FHE.allow(s.cumulativeDeviationMinutes, viewer);
        FHE.allow(s.productValueUSD, viewer);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalShipmentValue, viewer);
        FHE.allow(_totalQuarantinedValue, viewer);
        FHE.allow(_totalDeviationEvents, viewer);
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