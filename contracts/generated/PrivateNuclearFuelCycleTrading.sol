// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNuclearFuelCycleTrading
/// @notice Encrypted nuclear fuel cycle commodity trading: hidden enriched uranium prices,
///         confidential conversion capacity bookings, private long-term supply agreements,
///         and encrypted IAEA safeguards compliance scores.
contract PrivateNuclearFuelCycleTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FuelComponent { UraniumConcentrate, UF6Conversion, EnrichmentSWU, FuelFabrication }

    struct FuelContract {
        address supplier;
        address utility;
        FuelComponent component;
        string safeguardsRef;
        euint64 quantityKgU;           // encrypted quantity in kg uranium
        euint64 pricePerKgUSD;         // encrypted price per kg
        euint64 totalContractUSD;      // encrypted total contract value
        euint16 iaaeComplianceScore;   // encrypted IAEA compliance score
        euint8  proliferationRiskScore;// encrypted proliferation risk (0-100)
        uint256 deliveryDate;
        bool settled;
    }

    mapping(uint256 => FuelContract) private contracts_;
    mapping(address => bool) public isIAEAInspector;
    mapping(address => bool) public isLicensedUtility;

    uint256 public contractCount;
    euint64 private _totalVolumeKgU;
    euint64 private _totalContractValueUSD;

    event FuelContractCreated(uint256 indexed id, FuelComponent component);
    event DeliverySettled(uint256 indexed id, uint256 settledAt);

    modifier onlyIAEAInspector() {
        require(isIAEAInspector[msg.sender] || msg.sender == owner(), "Not IAEA inspector");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVolumeKgU = FHE.asEuint64(0);
        _totalContractValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalVolumeKgU);
        FHE.allowThis(_totalContractValueUSD);
        isIAEAInspector[msg.sender] = true;
        isLicensedUtility[msg.sender] = true;
    }

    function addInspector(address i) external onlyOwner { isIAEAInspector[i] = true; }
    function addUtility(address u) external onlyOwner { isLicensedUtility[u] = true; }

    function createFuelContract(
        address utility, FuelComponent component, string calldata safeguardsRef,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 deliveryDays
    ) external returns (uint256 id) {
        require(isLicensedUtility[utility], "Not licensed utility");
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint64 total = FHE.mul(qty, price);
        id = contractCount++;
        contracts_[id] = FuelContract({
            supplier: msg.sender, utility: utility, component: component,
            safeguardsRef: safeguardsRef, quantityKgU: qty, pricePerKgUSD: price,
            totalContractUSD: total, iaaeComplianceScore: FHE.asEuint16(0),
            proliferationRiskScore: FHE.asEuint8(0),
            deliveryDate: block.timestamp + deliveryDays * 1 days, settled: false
        });
        _totalVolumeKgU = FHE.add(_totalVolumeKgU, qty);
        _totalContractValueUSD = FHE.add(_totalContractValueUSD, total);
        FHE.allowThis(contracts_[id].quantityKgU); FHE.allow(contracts_[id].quantityKgU, msg.sender); FHE.allow(contracts_[id].quantityKgU, utility);
        FHE.allowThis(contracts_[id].pricePerKgUSD); FHE.allow(contracts_[id].pricePerKgUSD, msg.sender); FHE.allow(contracts_[id].pricePerKgUSD, utility);
        FHE.allowThis(contracts_[id].totalContractUSD); FHE.allow(contracts_[id].totalContractUSD, msg.sender); FHE.allow(contracts_[id].totalContractUSD, utility);
        FHE.allowThis(contracts_[id].iaaeComplianceScore);
        FHE.allowThis(contracts_[id].proliferationRiskScore);
        FHE.allowThis(_totalVolumeKgU);
        FHE.allowThis(_totalContractValueUSD);
        emit FuelContractCreated(id, component);
    }

    function certifyCompliance(
        uint256 contractId,
        externalEuint16 encCompliance, bytes calldata cProof,
        externalEuint8 encRisk, bytes calldata rProof
    ) external onlyIAEAInspector {
        contracts_[contractId].iaaeComplianceScore = FHE.fromExternal(encCompliance, cProof);
        contracts_[contractId].proliferationRiskScore = FHE.fromExternal(encRisk, rProof);
        FHE.allowThis(contracts_[contractId].iaaeComplianceScore);
        FHE.allowThis(contracts_[contractId].proliferationRiskScore);
    }

    function settleDelivery(uint256 contractId) external nonReentrant {
        FuelContract storage c = contracts_[contractId];
        require(block.timestamp >= c.deliveryDate && !c.settled, "Not yet deliverable");
        require(msg.sender == c.utility || msg.sender == c.supplier, "Not party");
        c.settled = true;
        emit DeliverySettled(contractId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeKgU, viewer);
        FHE.allow(_totalContractValueUSD, viewer);
    }
}
