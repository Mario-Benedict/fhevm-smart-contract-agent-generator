// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateEquipmentRentalPlatform
/// @notice Industrial equipment rental marketplace: encrypted daily rates, encrypted utilization metrics,
///         encrypted damage deposit scoring, and private maintenance cost pass-through tracking.
contract PrivateEquipmentRentalPlatform is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EquipmentCategory { EXCAVATOR, CRANE, FORKLIFT, GENERATOR, SCAFFOLD, PUMP, COMPRESSOR }

    struct Equipment {
        string serialNumber;
        EquipmentCategory category;
        string model;
        address owner_;
        euint64 dailyRateUSD;         // encrypted daily rental rate
        euint64 weeklyRateUSD;        // encrypted weekly rate (discounted)
        euint64 depositAmountUSD;     // encrypted security deposit
        euint64 utilizationRateBps;   // encrypted utilization rate
        euint64 maintenanceCostUSD;   // encrypted lifetime maintenance cost
        euint64 currentValue;         // encrypted current market value
        bool available;
    }

    struct RentalAgreement {
        uint256 equipmentId;
        address renter;
        euint64 totalRentUSD;         // encrypted total rental cost
        euint64 depositPaid;          // encrypted deposit paid
        euint64 damageCostUSD;        // encrypted damage assessed
        euint64 depositRefund;        // encrypted deposit refund after damage
        uint256 startDate;
        uint256 endDate;
        bool returned;
        bool deposited;
    }

    mapping(uint256 => Equipment) private equipment;
    mapping(uint256 => RentalAgreement) private rentals;
    uint256 public equipmentCount;
    uint256 public rentalCount;
    euint64 private _totalPlatformRevenue;
    mapping(address => bool) public isPlatformManager;

    event EquipmentListed(uint256 indexed id, string serial, EquipmentCategory cat);
    event RentalStarted(uint256 indexed rentalId, uint256 equipmentId, address renter);
    event EquipmentReturned(uint256 indexed rentalId);
    event DamageAssessed(uint256 indexed rentalId);

    constructor() Ownable(msg.sender) {
        _totalPlatformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalPlatformRevenue);
        isPlatformManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isPlatformManager[m] = true; }

    function listEquipment(
        string calldata serial, EquipmentCategory cat, string calldata model,
        externalEuint64 encDaily, bytes calldata dProof,
        externalEuint64 encWeekly, bytes calldata wProof,
        externalEuint64 encDeposit, bytes calldata depProof,
        externalEuint64 encValue, bytes calldata vProof
    ) external returns (uint256 id) {
        euint64 daily = FHE.fromExternal(encDaily, dProof);
        euint64 weekly = FHE.fromExternal(encWeekly, wProof);
        euint64 deposit = FHE.fromExternal(encDeposit, depProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        id = equipmentCount++;
        equipment[id].serialNumber = serial;
        equipment[id].category = cat;
        equipment[id].model = model;
        equipment[id].owner_ = msg.sender;
        equipment[id].dailyRateUSD = daily;
        equipment[id].weeklyRateUSD = weekly;
        equipment[id].depositAmountUSD = deposit;
        equipment[id].utilizationRateBps = FHE.asEuint64(0);
        equipment[id].maintenanceCostUSD = FHE.asEuint64(0);
        equipment[id].currentValue = value;
        equipment[id].available = true;
        FHE.allowThis(equipment[id].dailyRateUSD);
        FHE.allowThis(equipment[id].weeklyRateUSD);
        FHE.allowThis(equipment[id].depositAmountUSD);
        FHE.allowThis(equipment[id].utilizationRateBps);
        FHE.allowThis(equipment[id].currentValue);
        FHE.allow(equipment[id].dailyRateUSD, msg.sender);
        emit EquipmentListed(id, serial, cat);
    }

    function startRental(
        uint256 equipmentId, uint256 endDate,
        externalEuint64 encDeposit, bytes calldata proof
    ) external nonReentrant returns (uint256 rentalId) {
        Equipment storage eq = equipment[equipmentId];
        require(eq.available, "Not available");
        euint64 depositPaid = FHE.fromExternal(encDeposit, proof);
        ebool depositSufficient = FHE.ge(depositPaid, eq.depositAmountUSD);
        // depositSufficient is encrypted; cannot require on ebool in FHE context
        uint256 rentalDays = (endDate - block.timestamp) / 86400;
        euint64 totalRent = rentalDays >= 7 ?
            FHE.mul(eq.weeklyRateUSD, FHE.asEuint64(uint64(rentalDays / 7))) :
            FHE.mul(eq.dailyRateUSD, FHE.asEuint64(uint64(rentalDays)));
        rentalId = rentalCount++;
        rentals[rentalId].equipmentId = equipmentId;
        rentals[rentalId].renter = msg.sender;
        rentals[rentalId].totalRentUSD = totalRent;
        rentals[rentalId].depositPaid = depositPaid;
        rentals[rentalId].damageCostUSD = FHE.asEuint64(0);
        rentals[rentalId].depositRefund = FHE.asEuint64(0);
        rentals[rentalId].startDate = block.timestamp;
        rentals[rentalId].endDate = endDate;
        rentals[rentalId].returned = false;
        rentals[rentalId].deposited = true;
        eq.available = false;
        euint64 platformFee = FHE.div(totalRent, 20); // 5% fee
        _totalPlatformRevenue = FHE.add(_totalPlatformRevenue, platformFee);
        FHE.allowThis(rentals[rentalId].totalRentUSD);
        FHE.allowThis(rentals[rentalId].depositPaid);
        FHE.allowThis(rentals[rentalId].depositRefund);
        FHE.allow(rentals[rentalId].totalRentUSD, msg.sender);
        FHE.allow(rentals[rentalId].depositPaid, msg.sender);
        FHE.allowThis(_totalPlatformRevenue);
        emit RentalStarted(rentalId, equipmentId, msg.sender);
    }

    function returnEquipment(uint256 rentalId) external {
        RentalAgreement storage rental = rentals[rentalId];
        require(rental.renter == msg.sender && !rental.returned, "Not renter");
        Equipment storage eq = equipment[rental.equipmentId];
        eq.available = true;
        rental.returned = true;
        // Update utilization rate
        uint256 rentalDays = (rental.endDate - rental.startDate) / 86400;
        eq.utilizationRateBps = FHE.add(eq.utilizationRateBps, FHE.asEuint64(uint64(rentalDays * 10)));
        FHE.allowThis(eq.utilizationRateBps);
        emit EquipmentReturned(rentalId);
    }

    function assessDamage(
        uint256 rentalId,
        externalEuint64 encDamage, bytes calldata proof
    ) external {
        require(isPlatformManager[msg.sender], "Not manager");
        RentalAgreement storage rental = rentals[rentalId];
        require(rental.returned, "Not returned");
        euint64 damage = FHE.fromExternal(encDamage, proof);
        rental.damageCostUSD = damage;
        ebool depositCovers = FHE.ge(rental.depositPaid, damage);
        rental.depositRefund = FHE.select(depositCovers,
            FHE.sub(rental.depositPaid, damage), FHE.asEuint64(0));
        FHE.allowThis(rental.damageCostUSD);
        FHE.allowThis(rental.depositRefund);
        FHE.allow(rental.depositRefund, rental.renter);
        emit DamageAssessed(rentalId);
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