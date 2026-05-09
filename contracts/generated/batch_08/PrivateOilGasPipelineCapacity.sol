// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateOilGasPipelineCapacity
/// @notice Oil & gas pipeline capacity trading: encrypted throughput bids, encrypted tariff rates,
///         encrypted shipper balances, and confidential interruptible vs firm service allocation.
contract PrivateOilGasPipelineCapacity is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ServiceType { FIRM, INTERRUPTIBLE }

    struct CapacitySegment {
        string segmentId;
        euint64 totalCapacityMcf;     // encrypted max daily capacity (Mcf)
        euint64 firmAllocatedMcf;     // encrypted firm service allocation
        euint64 interruptibleMcf;     // encrypted interruptible allocation
        euint64 tariffRateUSDPerMcf;  // encrypted tariff rate
        euint64 utilization;          // encrypted current utilization
        bool active;
    }

    struct ShipperAccount {
        euint64 prepaidBalance;       // encrypted USD prepaid credit
        euint64 totalVolumeMcf;       // encrypted lifetime shipped volume
        euint64 firmContractMcf;      // encrypted firm contract capacity
        euint64 debtBalance;          // encrypted outstanding debt
        bool approved;
    }

    struct NominationRequest {
        uint256 segmentId;
        address shipper;
        ServiceType serviceType;
        euint64 nominatedMcf;        // encrypted nomination
        euint64 confirmedMcf;        // encrypted confirmed quantity
        uint256 gasDayStart;
        bool confirmed;
        bool interrupted;
    }

    mapping(uint256 => CapacitySegment) private segments;
    mapping(address => ShipperAccount) private shippers;
    mapping(uint256 => NominationRequest) private nominations;
    uint256 public segmentCount;
    uint256 public nominationCount;
    mapping(address => bool) public isOperator;

    event SegmentRegistered(uint256 indexed id, string segmentId);
    event NominationSubmitted(uint256 indexed nomId, uint256 segmentId, address shipper);
    event NominationConfirmed(uint256 indexed nomId);
    event ServiceInterrupted(uint256 indexed nomId);
    event ShipperApproved(address indexed shipper);

    constructor() Ownable(msg.sender) {
        isOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isOperator[op] = true; }

    function registerSegment(
        string calldata segmentId,
        externalEuint64 encCapacity, bytes calldata cProof,
        externalEuint64 encTariff, bytes calldata tProof
    ) external returns (uint256 id) {
        require(isOperator[msg.sender], "Not operator");
        euint64 cap = FHE.fromExternal(encCapacity, cProof);
        euint64 tariff = FHE.fromExternal(encTariff, tProof);
        id = segmentCount++;
        segments[id] = CapacitySegment({
            segmentId: segmentId, totalCapacityMcf: cap,
            firmAllocatedMcf: FHE.asEuint64(0),
            interruptibleMcf: FHE.asEuint64(0),
            tariffRateUSDPerMcf: tariff,
            utilization: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(segments[id].totalCapacityMcf);
        FHE.allowThis(segments[id].firmAllocatedMcf);
        FHE.allowThis(segments[id].interruptibleMcf);
        FHE.allowThis(segments[id].tariffRateUSDPerMcf);
        FHE.allowThis(segments[id].utilization);
        emit SegmentRegistered(id, segmentId);
    }

    function approveShipper(
        address shipper,
        externalEuint64 encBalance, bytes calldata bProof,
        externalEuint64 encFirmCap, bytes calldata fProof
    ) external {
        require(isOperator[msg.sender], "Not operator");
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        euint64 firmCap = FHE.fromExternal(encFirmCap, fProof);
        shippers[shipper] = ShipperAccount({
            prepaidBalance: balance, totalVolumeMcf: FHE.asEuint64(0),
            firmContractMcf: firmCap, debtBalance: FHE.asEuint64(0), approved: true
        });
        FHE.allowThis(shippers[shipper].prepaidBalance);
        FHE.allowThis(shippers[shipper].firmContractMcf);
        FHE.allowThis(shippers[shipper].totalVolumeMcf);
        FHE.allowThis(shippers[shipper].debtBalance);
        FHE.allow(shippers[shipper].prepaidBalance, shipper);
        FHE.allow(shippers[shipper].firmContractMcf, shipper);
        emit ShipperApproved(shipper);
    }

    function nominateCapacity(
        uint256 segmentId,
        ServiceType svcType,
        externalEuint64 encMcf, bytes calldata proof,
        uint256 gasDayStart
    ) external nonReentrant returns (uint256 nomId) {
        require(shippers[msg.sender].approved, "Not approved");
        CapacitySegment storage seg = segments[segmentId];
        require(seg.active, "Segment inactive");
        euint64 mcf = FHE.fromExternal(encMcf, proof);
        // Firm service: check against firm contract cap
        if (svcType == ServiceType.FIRM) {
            ebool withinFirm = FHE.le(mcf, shippers[msg.sender].firmContractMcf);
            mcf = FHE.select(withinFirm, mcf, shippers[msg.sender].firmContractMcf);
        }
        nomId = nominationCount++;
        nominations[nomId] = NominationRequest({
            segmentId: segmentId, shipper: msg.sender, serviceType: svcType,
            nominatedMcf: mcf, confirmedMcf: FHE.asEuint64(0),
            gasDayStart: gasDayStart, confirmed: false, interrupted: false
        });
        FHE.allowThis(nominations[nomId].nominatedMcf);
        FHE.allowThis(nominations[nomId].confirmedMcf);
        emit NominationSubmitted(nomId, segmentId, msg.sender);
    }

    function confirmNomination(uint256 nomId, externalEuint64 encConfirmed, bytes calldata proof) external {
        require(isOperator[msg.sender], "Not operator");
        NominationRequest storage nom = nominations[nomId];
        require(!nom.confirmed && !nom.interrupted, "Already processed");
        euint64 confirmed = FHE.fromExternal(encConfirmed, proof);
        // Cannot confirm more than nominated
        ebool withinNom = FHE.le(confirmed, nom.nominatedMcf);
        nom.confirmedMcf = FHE.select(withinNom, confirmed, nom.nominatedMcf);
        // Calculate tariff charge
        euint64 charge = FHE.mul(nom.confirmedMcf, segments[nom.segmentId].tariffRateUSDPerMcf);
        // Deduct from shipper balance
        ebool hasFunds = FHE.ge(shippers[nom.shipper].prepaidBalance, charge);
        euint64 deduct = FHE.select(hasFunds, charge, shippers[nom.shipper].prepaidBalance);
        euint64 debt = FHE.select(hasFunds, FHE.asEuint64(0), FHE.sub(charge, deduct));
        shippers[nom.shipper].prepaidBalance = FHE.sub(shippers[nom.shipper].prepaidBalance, deduct);
        shippers[nom.shipper].debtBalance = FHE.add(shippers[nom.shipper].debtBalance, debt);
        shippers[nom.shipper].totalVolumeMcf = FHE.add(shippers[nom.shipper].totalVolumeMcf, nom.confirmedMcf);
        // Update segment utilization
        segments[nom.segmentId].utilization = FHE.add(segments[nom.segmentId].utilization, nom.confirmedMcf);
        nom.confirmed = true;
        FHE.allowThis(nom.confirmedMcf);
        FHE.allow(nom.confirmedMcf, nom.shipper);
        FHE.allowThis(shippers[nom.shipper].prepaidBalance);
        FHE.allow(shippers[nom.shipper].prepaidBalance, nom.shipper);
        FHE.allowThis(shippers[nom.shipper].debtBalance);
        FHE.allowThis(segments[nom.segmentId].utilization);
        emit NominationConfirmed(nomId);
    }

    function interruptService(uint256 nomId) external {
        require(isOperator[msg.sender], "Not operator");
        NominationRequest storage nom = nominations[nomId];
        require(nom.serviceType == ServiceType.INTERRUPTIBLE, "Cannot interrupt FIRM");
        nom.interrupted = true;
        nom.confirmedMcf = FHE.asEuint64(0);
        FHE.allowThis(nom.confirmedMcf);
        emit ServiceInterrupted(nomId);
    }
}
