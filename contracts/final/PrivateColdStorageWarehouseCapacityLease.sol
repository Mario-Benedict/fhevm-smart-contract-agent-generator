// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateColdStorageWarehouseCapacityLease
/// @notice Encrypted cold storage warehouse capacity: hidden lease rates per pallet position,
///         confidential temperature zone compliance scores, private hazardous goods surcharges,
///         and encrypted throughput handling fee calculations.
contract PrivateColdStorageWarehouseCapacityLease is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TemperatureZone { Ambient, Chilled, Frozen, DeepFreeze, ULT }
    enum GoodsCategory { FoodGrade, Pharmaceutical, HazardousChem, Cosmetics, Electronics }

    struct ColdStorageLease {
        address warehouseOperator;
        address lessee;
        TemperatureZone temperatureZone;
        GoodsCategory goodsCategory;
        string warehouseRef;
        euint32 palletPositionsLeased;  // encrypted pallet count
        euint64 monthlyRatePerPalletUSD;// encrypted rate per pallet
        euint64 handlingFeePerPalletUSD;// encrypted handling fee
        euint16 temperatureComplianceBps; // encrypted temp compliance score
        euint64 hazardousSurchargeUSD;  // encrypted hazardous surcharge
        euint64 totalMonthlyBillUSD;    // encrypted monthly bill
        euint64 totalPaidUSD;           // encrypted total paid
        uint256 leaseStart;
        uint256 leaseEnd;
        bool active;
    }

    mapping(uint256 => ColdStorageLease) private leases;
    mapping(address => bool) public isFoodSafetyOfficer;

    uint256 public leaseCount;
    euint64 private _totalWarehouseRevenueUSD;

    event LeaseCreated(uint256 indexed id, TemperatureZone tempZone, GoodsCategory goods);
    event MonthlyInvoiceGenerated(uint256 indexed id, uint256 invoicedAt);

    modifier onlyFoodSafetyOfficer() {
        require(isFoodSafetyOfficer[msg.sender] || msg.sender == owner(), "Not food safety officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalWarehouseRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalWarehouseRevenueUSD);
        isFoodSafetyOfficer[msg.sender] = true;
    }

    function addFoodSafetyOfficer(address fso) external onlyOwner { isFoodSafetyOfficer[fso] = true; }

    function createLease(
        address lessee, TemperatureZone tempZone, GoodsCategory goodsCategory, string calldata warehouseRef,
        externalEuint32 encPallets, bytes calldata pProof,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encHandlingFee, bytes calldata hfProof,
        externalEuint16 encCompliance, bytes calldata compProof,
        externalEuint64 encHazardous, bytes calldata hazProof,
        uint256 termMonths
    ) external returns (uint256 id) {
        euint32 pallets = FHE.fromExternal(encPallets, pProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint64 handlingFee = FHE.fromExternal(encHandlingFee, hfProof);
        euint16 compliance = FHE.fromExternal(encCompliance, compProof);
        euint64 hazardous = FHE.fromExternal(encHazardous, hazProof);
        euint64 monthlyBill = FHE.add(FHE.mul(FHE.asEuint64(1), rate), handlingFee);
        id = leaseCount++;
        ColdStorageLease storage _s0 = leases[id];
        _s0.warehouseOperator = msg.sender;
        _s0.lessee = lessee;
        _s0.temperatureZone = tempZone;
        _s0.goodsCategory = goodsCategory;
        _s0.warehouseRef = warehouseRef;
        _s0.palletPositionsLeased = pallets;
        _s0.monthlyRatePerPalletUSD = rate;
        _s0.handlingFeePerPalletUSD = handlingFee;
        _s0.temperatureComplianceBps = compliance;
        _s0.hazardousSurchargeUSD = hazardous;
        _s0.totalMonthlyBillUSD = monthlyBill;
        _s0.totalPaidUSD = FHE.asEuint64(0);
        _s0.leaseStart = block.timestamp;
        _s0.leaseEnd = block.timestamp + termMonths * 30 days;
        _s0.active = true;
        FHE.allowThis(leases[id].palletPositionsLeased); FHE.allow(leases[id].palletPositionsLeased, lessee);
        FHE.allowThis(leases[id].monthlyRatePerPalletUSD); FHE.allow(leases[id].monthlyRatePerPalletUSD, lessee);
        FHE.allowThis(leases[id].handlingFeePerPalletUSD); FHE.allow(leases[id].handlingFeePerPalletUSD, lessee);
        FHE.allowThis(leases[id].temperatureComplianceBps);
        FHE.allowThis(leases[id].hazardousSurchargeUSD); FHE.allow(leases[id].hazardousSurchargeUSD, lessee);
        FHE.allowThis(leases[id].totalMonthlyBillUSD); FHE.allow(leases[id].totalMonthlyBillUSD, lessee);
        FHE.allowThis(leases[id].totalPaidUSD); FHE.allow(leases[id].totalPaidUSD, lessee);
        emit LeaseCreated(id, tempZone, goodsCategory);
    }

    function generateMonthlyInvoice(uint256 leaseId) external nonReentrant {
        ColdStorageLease storage l = leases[leaseId];
        require(msg.sender == l.lessee && l.active, "Not authorized");
        l.totalPaidUSD = FHE.add(l.totalPaidUSD, l.totalMonthlyBillUSD);
        _totalWarehouseRevenueUSD = FHE.add(_totalWarehouseRevenueUSD, l.totalMonthlyBillUSD);
        FHE.allowThis(l.totalPaidUSD); FHE.allow(l.totalPaidUSD, l.lessee); FHE.allow(l.totalPaidUSD, l.warehouseOperator);
        FHE.allowThis(_totalWarehouseRevenueUSD);
        emit MonthlyInvoiceGenerated(leaseId, block.timestamp);
    }

    function updateComplianceScore(
        uint256 leaseId,
        externalEuint16 encScore, bytes calldata proof
    ) external onlyFoodSafetyOfficer {
        leases[leaseId].temperatureComplianceBps = FHE.fromExternal(encScore, proof);
        FHE.allowThis(leases[leaseId].temperatureComplianceBps); FHE.allow(leases[leaseId].temperatureComplianceBps, leases[leaseId].warehouseOperator);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalWarehouseRevenueUSD, viewer);
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