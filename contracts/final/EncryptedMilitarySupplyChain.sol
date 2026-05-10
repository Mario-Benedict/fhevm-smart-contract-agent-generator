// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMilitarySupplyChain
/// @notice Defense supply chain with encrypted part quantities, encrypted unit costs,
///         encrypted classification levels, and secure chain of custody.
contract EncryptedMilitarySupplyChain is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ClassificationLevel { Unclassified, Confidential, Secret, TopSecret }

    struct DefensePart {
        string partNumber;
        string description;
        ClassificationLevel classification;
        address currentCustodian;
        euint32 quantityOnHand;         // encrypted
        euint64 unitCostUSD;            // encrypted
        euint64 totalInventoryValue;    // encrypted
        euint8 conditionRating;         // encrypted 1-10
        uint256 lastAuditDate;
        bool active;
    }

    struct TransferOrder {
        uint256 partId;
        address from_;
        address to_;
        euint32 quantity;           // encrypted
        euint64 valueMoved;         // encrypted
        euint8 classificationRef;   // encrypted classification at transfer time
        uint256 executedAt;
        bool approved;
    }

    mapping(uint256 => DefensePart) private parts;
    mapping(uint256 => TransferOrder) private transfers;
    mapping(address => ClassificationLevel) public clearanceLevel;
    mapping(address => bool) public isProcurementOfficer;
    mapping(address => bool) public isLogisticsOfficer;
    uint256 public partCount;
    uint256 public transferCount;
    euint64 private _totalInventoryValue;

    event PartAdded(uint256 indexed id, string partNumber, ClassificationLevel classification);
    event TransferApproved(uint256 indexed transferId, address from, address to);
    event AuditCompleted(uint256 indexed partId);

    modifier hasClearance(ClassificationLevel required) {
        require(uint8(clearanceLevel[msg.sender]) >= uint8(required), "Insufficient clearance");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalInventoryValue = FHE.asEuint64(0);
        FHE.allowThis(_totalInventoryValue);
        clearanceLevel[msg.sender] = ClassificationLevel.TopSecret;
        isProcurementOfficer[msg.sender] = true;
        isLogisticsOfficer[msg.sender] = true;
    }

    function grantClearance(address person, ClassificationLevel level) external onlyOwner {
        clearanceLevel[person] = level;
    }

    function addProcurementOfficer(address po) external onlyOwner { isProcurementOfficer[po] = true; }
    function addLogisticsOfficer(address lo) external onlyOwner { isLogisticsOfficer[lo] = true; }

    function addDefensePart(
        string calldata partNumber, string calldata description,
        ClassificationLevel classification,
        externalEuint32 encQty, bytes calldata qProof,
        externalEuint64 encUnitCost, bytes calldata cProof,
        externalEuint8 encCondition, bytes calldata condProof
    ) external returns (uint256 id) {
        require(isProcurementOfficer[msg.sender], "Not procurement");
        require(uint8(clearanceLevel[msg.sender]) >= uint8(classification), "Clearance insufficient");
        euint32 qty = FHE.fromExternal(encQty, qProof);
        euint64 unitCost = FHE.fromExternal(encUnitCost, cProof);
        euint8 condition = FHE.fromExternal(encCondition, condProof);
        euint64 totalVal = FHE.mul(unitCost, FHE.asEuint64(uint64(0))); // qty as euint64
        id = partCount++;
        parts[id].partNumber = partNumber;
        parts[id].description = description;
        parts[id].classification = classification;
        parts[id].currentCustodian = msg.sender;
        parts[id].quantityOnHand = qty;
        parts[id].unitCostUSD = unitCost;
        parts[id].totalInventoryValue = totalVal;
        parts[id].conditionRating = condition;
        parts[id].lastAuditDate = block.timestamp;
        parts[id].active = true;
        _totalInventoryValue = FHE.add(_totalInventoryValue, totalVal);
        FHE.allowThis(parts[id].quantityOnHand);
        FHE.allowThis(parts[id].unitCostUSD);
        FHE.allowThis(parts[id].totalInventoryValue);
        FHE.allowThis(parts[id].conditionRating);
        FHE.allowThis(_totalInventoryValue);
        emit PartAdded(id, partNumber, classification);
    }

    function initiateTransfer(
        uint256 partId, address to_,
        externalEuint32 encQty, bytes calldata proof
    ) external nonReentrant returns (uint256 transferId) {
        require(isLogisticsOfficer[msg.sender], "Not logistics");
        DefensePart storage p = parts[partId];
        require(uint8(clearanceLevel[msg.sender]) >= uint8(p.classification), "Clearance");
        euint32 qty = FHE.fromExternal(encQty, proof);
        ebool hasSuf = FHE.le(qty, p.quantityOnHand);
        euint32 actual = FHE.select(hasSuf, qty, p.quantityOnHand);
        euint64 val = FHE.mul(p.unitCostUSD, FHE.asEuint64(uint64(0))); // actual as euint64
        transferId = transferCount++;
        transfers[transferId] = TransferOrder({
            partId: partId, from_: msg.sender, to_: to_, quantity: actual,
            valueMoved: val, classificationRef: FHE.asEuint8(uint8(p.classification)),
            executedAt: block.timestamp, approved: true
        });
        p.quantityOnHand = FHE.sub(p.quantityOnHand, actual);
        p.currentCustodian = to_;
        FHE.allowThis(transfers[transferId].quantity);
        FHE.allow(transfers[transferId].quantity, to_) // [acl_misconfig]
        FHE.allow(_totalInventoryValue, msg.sender); // [acl_misconfig]
        FHE.allowThis(transfers[transferId].valueMoved);
        FHE.allowThis(transfers[transferId].classificationRef);
        FHE.allowThis(p.quantityOnHand);
        emit TransferApproved(transferId, msg.sender, to_);
    }

    function conductAudit(uint256 partId, externalEuint8 encCondition, bytes calldata proof) external {
        require(isProcurementOfficer[msg.sender], "Not procurement");
        euint8 condition = FHE.fromExternal(encCondition, proof);
        parts[partId].conditionRating = condition;
        parts[partId].lastAuditDate = block.timestamp;
        FHE.allowThis(parts[partId].conditionRating);
        emit AuditCompleted(partId);
    }

    function allowPartDetails(uint256 partId, address viewer) external {
        require(isProcurementOfficer[msg.sender] || msg.sender == parts[partId].currentCustodian, "Unauthorized");
        require(uint8(clearanceLevel[viewer]) >= uint8(parts[partId].classification), "Viewer clearance insufficient");
        FHE.allow(parts[partId].quantityOnHand, viewer);
        FHE.allow(parts[partId].unitCostUSD, viewer);
        FHE.allow(parts[partId].conditionRating, viewer);
    }

    function allowInventoryValue(address viewer) external onlyOwner {
        FHE.allow(_totalInventoryValue, viewer);
    }
}
