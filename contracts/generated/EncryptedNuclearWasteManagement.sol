// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedNuclearWasteManagement
/// @notice Nuclear waste tracking: encrypted radioactivity levels, storage capacities,
///         shipment manifests with encrypted isotope quantities, and regulatory compliance.
contract EncryptedNuclearWasteManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum WasteClass { LowLevel, IntermediateLevel, HighLevel, TRU }
    enum ShipmentStatus { Prepared, InTransit, Received, Stored, Disposed }

    struct WastePackage {
        string packageId;
        WasteClass wasteClass;
        euint32 radioactivityBq;       // encrypted becquerel level
        euint16 halfLifeYears;         // encrypted half-life years
        euint32 massKg;                // encrypted mass in kg
        address producer;
        uint256 producedAt;
        bool immobilized;
    }

    struct StorageFacility {
        string name;
        string location;
        euint32 capacityKg;            // encrypted total capacity
        euint32 usedCapacityKg;        // encrypted used capacity
        euint32 maxRadioactivityBq;    // encrypted max allowed radioactivity
        euint32 currentRadioactivityBq;// encrypted current total radioactivity
        bool licensed;
        address operator_;
    }

    struct WasteShipment {
        uint256 packageId;
        uint256 facilityId;
        euint32 quantityKg;            // encrypted quantity
        euint32 radioactivityBq;       // encrypted radioactivity at shipment
        address carrier;
        ShipmentStatus status;
        uint256 dispatchedAt;
        uint256 receivedAt;
    }

    mapping(uint256 => WastePackage) private packages;
    mapping(uint256 => StorageFacility) private facilities;
    mapping(uint256 => WasteShipment) private shipments;
    mapping(address => bool) public isRegulator;
    mapping(address => bool) public isCarrier;
    mapping(address => bool) public isFacilityOperator;
    uint256 public packageCount;
    uint256 public facilityCount;
    uint256 public shipmentCount;
    euint32 private _totalNationalRadioactivity;

    event PackageCreated(uint256 indexed id, WasteClass class_);
    event FacilityRegistered(uint256 indexed id, string name);
    event ShipmentDispatched(uint256 indexed id, uint256 packageId);
    event ShipmentReceived(uint256 indexed id, uint256 facilityId);

    modifier onlyRegulator() {
        require(isRegulator[msg.sender] || msg.sender == owner(), "Not regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNationalRadioactivity = FHE.asEuint32(0);
        FHE.allowThis(_totalNationalRadioactivity);
        isRegulator[msg.sender] = true;
    }

    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function addCarrier(address c) external onlyOwner { isCarrier[c] = true; }
    function addFacilityOperator(address f) external onlyOwner { isFacilityOperator[f] = true; }

    function createPackage(
        string calldata pkgId, WasteClass class_,
        externalEuint32 encRadioactivity, bytes calldata rProof,
        externalEuint16 encHalfLife, bytes calldata hlProof,
        externalEuint32 encMass, bytes calldata mProof
    ) external returns (uint256 id) {
        euint32 radioactivity = FHE.fromExternal(encRadioactivity, rProof);
        euint16 halfLife = FHE.fromExternal(encHalfLife, hlProof);
        euint32 mass = FHE.fromExternal(encMass, mProof);
        id = packageCount++;
        packages[id] = WastePackage({
            packageId: pkgId, wasteClass: class_, radioactivityBq: radioactivity,
            halfLifeYears: halfLife, massKg: mass, producer: msg.sender,
            producedAt: block.timestamp, immobilized: false
        });
        _totalNationalRadioactivity = FHE.add(_totalNationalRadioactivity, radioactivity);
        FHE.allowThis(packages[id].radioactivityBq);
        FHE.allowThis(packages[id].halfLifeYears);
        FHE.allowThis(packages[id].massKg);
        FHE.allowThis(_totalNationalRadioactivity);
        emit PackageCreated(id, class_);
    }

    function registerFacility(
        string calldata name, string calldata location,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint32 encMaxRadioactivity, bytes calldata mrProof,
        address operator_
    ) external onlyRegulator returns (uint256 id) {
        euint32 capacity = FHE.fromExternal(encCapacity, capProof);
        euint32 maxRadioactivity = FHE.fromExternal(encMaxRadioactivity, mrProof);
        id = facilityCount++;
        facilities[id] = StorageFacility({
            name: name, location: location, capacityKg: capacity,
            usedCapacityKg: FHE.asEuint32(0), maxRadioactivityBq: maxRadioactivity,
            currentRadioactivityBq: FHE.asEuint32(0), licensed: true, operator_: operator_
        });
        FHE.allowThis(facilities[id].capacityKg);
        FHE.allow(facilities[id].capacityKg, operator_);
        FHE.allowThis(facilities[id].usedCapacityKg);
        FHE.allow(facilities[id].usedCapacityKg, operator_);
        FHE.allowThis(facilities[id].maxRadioactivityBq);
        FHE.allowThis(facilities[id].currentRadioactivityBq);
        emit FacilityRegistered(id, name);
    }

    function dispatchShipment(
        uint256 pkgId, uint256 facilityId, address carrier,
        externalEuint32 encQty, bytes calldata qProof
    ) external nonReentrant returns (uint256 id) {
        require(isCarrier[carrier], "Not licensed carrier");
        euint32 qty = FHE.fromExternal(encQty, qProof);
        id = shipmentCount++;
        shipments[id] = WasteShipment({
            packageId: pkgId, facilityId: facilityId, quantityKg: qty,
            radioactivityBq: packages[pkgId].radioactivityBq,
            carrier: carrier, status: ShipmentStatus.InTransit,
            dispatchedAt: block.timestamp, receivedAt: 0
        });
        FHE.allowThis(shipments[id].quantityKg);
        FHE.allowThis(shipments[id].radioactivityBq);
        FHE.allow(shipments[id].radioactivityBq, carrier);
        emit ShipmentDispatched(id, pkgId);
    }

    function confirmReceived(uint256 shipmentId) external {
        require(isFacilityOperator[msg.sender], "Not operator");
        WasteShipment storage s = shipments[shipmentId];
        require(s.status == ShipmentStatus.InTransit, "Not in transit");
        s.status = ShipmentStatus.Received;
        s.receivedAt = block.timestamp;
        StorageFacility storage fac = facilities[s.facilityId];
        fac.usedCapacityKg = FHE.add(fac.usedCapacityKg, s.quantityKg);
        fac.currentRadioactivityBq = FHE.add(fac.currentRadioactivityBq, s.radioactivityBq);
        FHE.allowThis(fac.usedCapacityKg);
        FHE.allowThis(fac.currentRadioactivityBq);
        emit ShipmentReceived(shipmentId, s.facilityId);
    }

    function allowPackageDetails(uint256 pkgId, address viewer) external onlyRegulator {
        FHE.allow(packages[pkgId].radioactivityBq, viewer);
        FHE.allow(packages[pkgId].halfLifeYears, viewer);
        FHE.allow(packages[pkgId].massKg, viewer);
    }

    function allowFacilityStats(uint256 facilityId, address viewer) external onlyRegulator {
        FHE.allow(facilities[facilityId].usedCapacityKg, viewer);
        FHE.allow(facilities[facilityId].currentRadioactivityBq, viewer);
    }

    function allowNationalStats(address viewer) external onlyOwner {
        FHE.allow(_totalNationalRadioactivity, viewer);
    }
}
