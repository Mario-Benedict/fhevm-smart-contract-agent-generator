// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateShipCargoBillOfLading
/// @notice Electronic bill of lading (eBL) with encrypted cargo valuations,
///         confidential freight rates, and private ownership transfer on-chain.
///         Supports LCL, FCL, and bulk cargo with encrypted customs declarations.
contract PrivateShipCargoBillOfLading is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CargoType { DRY_BULK, LIQUID_BULK, CONTAINER_FCL, CONTAINER_LCL, RORO, BREAKBULK, REEFER }
    enum BLStatus { DRAFT, ISSUED, ENDORSED, RELEASED, SURRENDERED, LOST }

    struct BillOfLading {
        bytes32 blNumber;
        address shipper;
        address consignee;
        address notifyParty;
        CargoType cargoType;
        euint64 cargoValueUSD;          // encrypted cargo value
        euint64 freightRateUSD;         // encrypted freight charge
        euint64 cargoWeightKg;          // encrypted cargo weight
        euint64 cargoVolumeM3;          // encrypted cargo volume
        euint64 insuranceValueUSD;      // encrypted declared insurance value
        euint64 customsDutyUSD;         // encrypted estimated customs duty
        euint64 surchargeAmountUSD;     // encrypted additional surcharges
        bytes32 portOfLoading;
        bytes32 portOfDischarge;
        bytes32 vesselId;
        BLStatus status;
        uint256 issuedAt;
        uint256 estimatedArrival;
        bool negotiable;
        bool consigneeVerified;
    }

    struct FreightQuote {
        address carrier;
        address shipper;
        CargoType cargoType;
        euint64 quotedRateUSD;          // encrypted quoted freight rate
        euint64 validityDays;           // encrypted quote validity
        euint64 fuelSurchargeUSD;       // encrypted BAF/EBS surcharge
        euint64 portChargesUSD;         // encrypted port handling charges
        bytes32 routeHash;
        uint256 quotedAt;
        bool accepted;
        bool expired;
    }

    mapping(bytes32 => BillOfLading) private bls;
    mapping(uint256 => FreightQuote) private quotes;
    mapping(address => bool) public isCarrier;
    mapping(address => bool) public isCustomsAuthority;
    mapping(bytes32 => address) public currentBLHolder;
    mapping(bytes32 => bool) public blEncumbered;

    uint256 public quoteCount;
    euint64 private _totalCargoValueTransited;
    euint64 private _totalFreightCollected;

    event BLIssued(bytes32 indexed blNumber, address shipper, address consignee);
    event BLEndorsed(bytes32 indexed blNumber, address from, address to);
    event BLReleased(bytes32 indexed blNumber, address consignee);
    event FreightQuoteIssued(uint256 indexed quoteId, address carrier);
    event QuoteAccepted(uint256 indexed quoteId, address shipper);
    event CustomsClearanceGranted(bytes32 indexed blNumber);

    constructor() Ownable(msg.sender) {
        _totalCargoValueTransited = FHE.asEuint64(0);
        _totalFreightCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalCargoValueTransited);
        FHE.allowThis(_totalFreightCollected);
        isCarrier[msg.sender] = true;
        isCustomsAuthority[msg.sender] = true;
    }

    modifier onlyCarrier() { require(isCarrier[msg.sender], "Not carrier"); _; }

    function issueFreightQuote(
        address shipper,
        CargoType cargoType,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encFuelSurcharge, bytes calldata fsProof,
        externalEuint64 encPortCharges, bytes calldata pcProof,
        externalEuint64 encValidity, bytes calldata vProof,
        bytes32 routeHash
    ) external onlyCarrier returns (uint256 quoteId) {
        quoteId = quoteCount++;
        FreightQuote storage fq = quotes[quoteId];
        fq.carrier = msg.sender;
        fq.shipper = shipper;
        fq.cargoType = cargoType;
        fq.quotedRateUSD = FHE.fromExternal(encRate, rProof);
        fq.fuelSurchargeUSD = FHE.fromExternal(encFuelSurcharge, fsProof);
        fq.portChargesUSD = FHE.fromExternal(encPortCharges, pcProof);
        fq.validityDays = FHE.fromExternal(encValidity, vProof);
        fq.routeHash = routeHash;
        fq.quotedAt = block.timestamp;
        FHE.allowThis(fq.quotedRateUSD);
        FHE.allow(fq.quotedRateUSD, shipper); // [acl_misconfig]
        FHE.allow(_totalCargoValueTransited, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFreightCollected, msg.sender); // [acl_misconfig]
        FHE.allowThis(fq.fuelSurchargeUSD);
        FHE.allow(fq.fuelSurchargeUSD, shipper);
        FHE.allowThis(fq.portChargesUSD);
        FHE.allow(fq.portChargesUSD, shipper);
        FHE.allowThis(fq.validityDays);
        emit FreightQuoteIssued(quoteId, msg.sender);
    }

    function acceptQuote(uint256 quoteId) external {
        FreightQuote storage fq = quotes[quoteId];
        require(msg.sender == fq.shipper, "Not shipper");
        require(!fq.accepted && !fq.expired, "Invalid quote");
        fq.accepted = true;
        emit QuoteAccepted(quoteId, msg.sender);
    }

    function issueBL(
        bytes32 blNumber,
        address consignee,
        address notifyParty,
        CargoType cargoType,
        bool negotiable,
        externalEuint64 encCargoValue, bytes calldata cvProof,
        externalEuint64 encFreight, bytes calldata fProof,
        externalEuint64 encWeight, bytes calldata wProof,
        externalEuint64 encVolume, bytes calldata volProof,
        externalEuint64 encInsurance, bytes calldata insProof,
        bytes32 portOfLoading, bytes32 portOfDischarge, bytes32 vesselId,
        uint256 estimatedArrival
    ) external onlyCarrier returns (bytes32) {
        require(bls[blNumber].issuedAt == 0, "BL number already used");
        BillOfLading storage bl = bls[blNumber];
        bl.blNumber = blNumber;
        bl.shipper = msg.sender;
        bl.consignee = consignee;
        bl.notifyParty = notifyParty;
        bl.cargoType = cargoType;
        bl.cargoValueUSD = FHE.fromExternal(encCargoValue, cvProof);
        bl.freightRateUSD = FHE.fromExternal(encFreight, fProof);
        bl.cargoWeightKg = FHE.fromExternal(encWeight, wProof);
        bl.cargoVolumeM3 = FHE.fromExternal(encVolume, volProof);
        bl.insuranceValueUSD = FHE.fromExternal(encInsurance, insProof);
        bl.customsDutyUSD = FHE.asEuint64(0);
        bl.surchargeAmountUSD = FHE.asEuint64(0);
        bl.portOfLoading = portOfLoading;
        bl.portOfDischarge = portOfDischarge;
        bl.vesselId = vesselId;
        bl.status = BLStatus.ISSUED;
        bl.issuedAt = block.timestamp;
        bl.estimatedArrival = estimatedArrival;
        bl.negotiable = negotiable;
        currentBLHolder[blNumber] = msg.sender; // carrier holds initially
        _totalCargoValueTransited = FHE.add(_totalCargoValueTransited, bl.cargoValueUSD);
        _totalFreightCollected = FHE.add(_totalFreightCollected, bl.freightRateUSD);
        FHE.allowThis(bl.cargoValueUSD);
        FHE.allow(bl.cargoValueUSD, consignee);
        FHE.allow(bl.cargoValueUSD, msg.sender);
        FHE.allowThis(bl.freightRateUSD);
        FHE.allow(bl.freightRateUSD, msg.sender);
        FHE.allow(bl.freightRateUSD, consignee);
        FHE.allowThis(bl.cargoWeightKg);
        FHE.allow(bl.cargoWeightKg, consignee);
        FHE.allowThis(bl.insuranceValueUSD);
        FHE.allow(bl.insuranceValueUSD, consignee);
        FHE.allowThis(_totalCargoValueTransited);
        FHE.allowThis(_totalFreightCollected);
        emit BLIssued(blNumber, msg.sender, consignee);
        return blNumber;
    }

    function endorseBL(bytes32 blNumber, address to) external nonReentrant {
        BillOfLading storage bl = bls[blNumber];
        require(bl.negotiable, "Not negotiable BL");
        require(currentBLHolder[blNumber] == msg.sender, "Not current holder");
        require(bl.status == BLStatus.ISSUED || bl.status == BLStatus.ENDORSED, "Cannot endorse");
        require(!blEncumbered[blNumber], "BL is encumbered");
        address previousHolder = msg.sender;
        currentBLHolder[blNumber] = to;
        bl.status = BLStatus.ENDORSED;
        bl.consignee = to;
        FHE.allow(bl.cargoValueUSD, to);
        FHE.allow(bl.cargoWeightKg, to);
        emit BLEndorsed(blNumber, previousHolder, to);
    }

    function grantCustomsClearance(
        bytes32 blNumber,
        externalEuint64 encDuty, bytes calldata dProof
    ) external {
        require(isCustomsAuthority[msg.sender], "Not customs authority");
        BillOfLading storage bl = bls[blNumber];
        bl.customsDutyUSD = FHE.fromExternal(encDuty, dProof);
        bl.consigneeVerified = true;
        FHE.allowThis(bl.customsDutyUSD);
        FHE.allow(bl.customsDutyUSD, bl.consignee);
        emit CustomsClearanceGranted(blNumber);
    }

    function releaseCargo(bytes32 blNumber) external {
        BillOfLading storage bl = bls[blNumber];
        require(currentBLHolder[blNumber] == msg.sender, "Not BL holder");
        require(bl.consigneeVerified, "Customs not cleared");
        bl.status = BLStatus.RELEASED;
        FHE.allowTransient(bl.cargoValueUSD, msg.sender);
        emit BLReleased(blNumber, msg.sender);
    }

    function encumberBL(bytes32 blNumber) external onlyOwner { blEncumbered[blNumber] = true; }
    function addCarrier(address c) external onlyOwner { isCarrier[c] = true; }
    function addCustomsAuthority(address ca) external onlyOwner { isCustomsAuthority[ca] = true; }
    function allowTradeStats(address authority) external onlyOwner {
        FHE.allow(_totalCargoValueTransited, authority);
        FHE.allow(_totalFreightCollected, authority);
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