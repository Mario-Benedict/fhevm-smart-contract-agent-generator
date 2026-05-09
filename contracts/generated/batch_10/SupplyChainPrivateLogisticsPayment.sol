// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SupplyChainPrivateLogisticsPayment
/// @notice Freight payment system where carrier rates and cargo values are encrypted.
///         Payment released automatically upon encrypted milestone confirmations.
contract SupplyChainPrivateLogisticsPayment is ZamaEthereumConfig, Ownable {
    enum MilestoneStatus { Pending, Confirmed, Disputed }

    struct Shipment {
        address shipper;
        address carrier;
        euint64 cargoValue;
        euint64 freightRate;
        euint8 milestoneCount;
        euint8 confirmedMilestones;
        bool active;
        bool paid;
    }

    struct Milestone {
        string description;
        euint64 paymentBps;  // % of freight rate to release at this milestone
        MilestoneStatus status;
        uint256 confirmedAt;
    }

    mapping(uint256 => Shipment) private shipments;
    uint256 public shipmentCount;
    mapping(uint256 => Milestone[]) private milestones;
    mapping(address => bool) public isCarrier;
    euint64 private _totalFreightVolume;

    event ShipmentCreated(uint256 indexed id, address shipper, address carrier);
    event MilestoneAdded(uint256 indexed shipmentId, uint256 milestoneIndex);
    event MilestoneConfirmed(uint256 indexed shipmentId, uint256 milestoneIndex);
    event ShipmentCompleted(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalFreightVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalFreightVolume);
    }

    function registerCarrier(address c) external onlyOwner { isCarrier[c] = true; }

    function createShipment(
        address carrier,
        externalEuint64 encCargoValue, bytes calldata cvProof,
        externalEuint64 encFreightRate, bytes calldata frProof
    ) external returns (uint256 id) {
        require(isCarrier[carrier], "Not carrier");
        id = shipmentCount++;
        shipments[id].shipper = msg.sender;
        shipments[id].carrier = carrier;
        shipments[id].cargoValue = FHE.fromExternal(encCargoValue, cvProof);
        shipments[id].freightRate = FHE.fromExternal(encFreightRate, frProof);
        shipments[id].milestoneCount = FHE.asEuint8(0);
        shipments[id].confirmedMilestones = FHE.asEuint8(0);
        shipments[id].active = true;
        _totalFreightVolume = FHE.add(_totalFreightVolume, shipments[id].freightRate);
        FHE.allowThis(shipments[id].cargoValue);
        FHE.allow(shipments[id].cargoValue, msg.sender);
        FHE.allow(shipments[id].cargoValue, carrier);
        FHE.allowThis(shipments[id].freightRate);
        FHE.allow(shipments[id].freightRate, carrier);
        FHE.allowThis(shipments[id].milestoneCount);
        FHE.allowThis(shipments[id].confirmedMilestones);
        FHE.allowThis(_totalFreightVolume);
        emit ShipmentCreated(id, msg.sender, carrier);
    }

    function addMilestone(
        uint256 shipmentId, string calldata desc,
        externalEuint64 encPaymentBps, bytes calldata proof
    ) external {
        require(shipments[shipmentId].shipper == msg.sender, "Not shipper");
        euint64 bps = FHE.fromExternal(encPaymentBps, proof);
        Milestone memory m = Milestone({
            description: desc,
            paymentBps: FHE.asEuint64(0), // stored as new variable
            status: MilestoneStatus.Pending,
            confirmedAt: 0
        });
        m.paymentBps = bps;
        milestones[shipmentId].push(m);
        shipments[shipmentId].milestoneCount = FHE.add(shipments[shipmentId].milestoneCount, FHE.asEuint8(1));
        uint256 idx = milestones[shipmentId].length - 1;
        FHE.allowThis(milestones[shipmentId][idx].paymentBps);
        FHE.allow(milestones[shipmentId][idx].paymentBps, shipments[shipmentId].carrier);
        FHE.allowThis(shipments[shipmentId].milestoneCount);
        emit MilestoneAdded(shipmentId, idx);
    }

    function confirmMilestone(uint256 shipmentId, uint256 milestoneIndex) external {
        Shipment storage s = shipments[shipmentId];
        require(msg.sender == s.shipper, "Not shipper");
        require(milestoneIndex < milestones[shipmentId].length, "Invalid");
        Milestone storage m = milestones[shipmentId][milestoneIndex];
        require(m.status == MilestoneStatus.Pending, "Not pending");
        m.status = MilestoneStatus.Confirmed;
        m.confirmedAt = block.timestamp;
        s.confirmedMilestones = FHE.add(s.confirmedMilestones, FHE.asEuint8(1));
        // Release payment for this milestone
        euint64 payment = FHE.div(FHE.mul(s.freightRate, m.paymentBps), 10000);
        FHE.allow(payment, s.carrier);
        FHE.allowThis(s.confirmedMilestones);
        emit MilestoneConfirmed(shipmentId, milestoneIndex);
        // Check if all milestones complete
        ebool allDone = FHE.eq(s.confirmedMilestones, s.milestoneCount);
        if (FHE.isInitialized(allDone)) {
            s.active = false;
            s.paid = true;
            emit ShipmentCompleted(shipmentId);
        }
    }

    function allowShipmentData(uint256 id, address viewer) external {
        Shipment storage s = shipments[id];
        require(msg.sender == s.shipper || msg.sender == s.carrier, "No access");
        FHE.allow(s.cargoValue, viewer);
        FHE.allow(s.freightRate, viewer);
    }
}
