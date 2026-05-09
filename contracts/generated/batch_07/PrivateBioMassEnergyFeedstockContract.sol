// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateBioMassEnergyFeedstockContract
/// @notice Encrypted biomass energy feedstock supply contracts: hidden biomass tonnage prices,
///         confidential calorific value specs, private penalty clauses for quality shortfalls,
///         and encrypted seasonal delivery schedules.
contract PrivateBioMassEnergyFeedstockContract is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BioMassType { WoodChips, AgriResidues, MunicipalSolidWaste, EnergyGrass, AlgaePellets }
    enum ContractStatus { Draft, Active, InDelivery, Settled, InDispute }

    struct FeedstockContract {
        address supplier;
        address energyProducer;
        BioMassType bioMassType;
        euint64 annualTonnesCommitted;  // encrypted annual volume
        euint64 pricePerTonneUSD;       // encrypted agreed price
        euint32 minimumCalorificKJkg;   // encrypted minimum energy content spec
        euint64 qualityPenaltyBps;      // encrypted penalty bps for below-spec
        euint64 totalContractValueUSD;  // encrypted total value
        euint64 deliveredTonnes;        // encrypted delivered volume
        euint64 penaltiesAssessedUSD;   // encrypted assessed penalties
        ContractStatus status;
        uint256 startDate;
        uint256 endDate;
    }

    mapping(uint256 => FeedstockContract) private contracts_;
    mapping(address => bool) public isQualityTester;

    uint256 public contractCount;
    euint64 private _totalContractValueUSD;
    euint64 private _totalPenaltiesUSD;

    event ContractCreated(uint256 indexed id, BioMassType bioMassType);
    event DeliveryRecorded(uint256 indexed contractId, uint256 recordedAt);
    event PenaltyAssessed(uint256 indexed contractId, uint256 assessedAt);

    modifier onlyQualityTester() {
        require(isQualityTester[msg.sender] || msg.sender == owner(), "Not quality tester");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalContractValueUSD = FHE.asEuint64(0);
        _totalPenaltiesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalContractValueUSD);
        FHE.allowThis(_totalPenaltiesUSD);
        isQualityTester[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addQualityTester(address qt) external onlyOwner { isQualityTester[qt] = true; }

    function createFeedstockContract(
        address energyProducer,
        BioMassType bioMassType,
        externalEuint64 encTonnes, bytes calldata tProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint32 encCalorific, bytes calldata cProof,
        externalEuint64 encPenaltyBps, bytes calldata penProof,
        uint256 durationDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        euint32 calorific = FHE.fromExternal(encCalorific, cProof);
        euint64 penaltyBps = FHE.fromExternal(encPenaltyBps, penProof);
        euint64 totalValue = FHE.mul(tonnes, price);
        id = contractCount++;
        FeedstockContract storage _s0 = contracts_[id];
        _s0.supplier = msg.sender;
        _s0.energyProducer = energyProducer;
        _s0.bioMassType = bioMassType;
        _s0.annualTonnesCommitted = tonnes;
        _s0.pricePerTonneUSD = price;
        _s0.minimumCalorificKJkg = calorific;
        _s0.qualityPenaltyBps = penaltyBps;
        _s0.totalContractValueUSD = totalValue;
        _s0.deliveredTonnes = FHE.asEuint64(0);
        _s0.penaltiesAssessedUSD = FHE.asEuint64(0);
        _s0.status = ContractStatus.Active;
        _s0.startDate = block.timestamp;
        _s0.endDate = block.timestamp + durationDays * 1 days;
        _totalContractValueUSD = FHE.add(_totalContractValueUSD, totalValue);
        FHE.allowThis(contracts_[id].annualTonnesCommitted); FHE.allow(contracts_[id].annualTonnesCommitted, msg.sender); FHE.allow(contracts_[id].annualTonnesCommitted, energyProducer);
        FHE.allowThis(contracts_[id].pricePerTonneUSD); FHE.allow(contracts_[id].pricePerTonneUSD, msg.sender); FHE.allow(contracts_[id].pricePerTonneUSD, energyProducer);
        FHE.allowThis(contracts_[id].minimumCalorificKJkg);
        FHE.allowThis(contracts_[id].qualityPenaltyBps);
        FHE.allowThis(contracts_[id].totalContractValueUSD); FHE.allow(contracts_[id].totalContractValueUSD, energyProducer);
        FHE.allowThis(contracts_[id].deliveredTonnes);
        FHE.allowThis(contracts_[id].penaltiesAssessedUSD);
        FHE.allowThis(_totalContractValueUSD);
        emit ContractCreated(id, bioMassType);
    }

    function recordDelivery(
        uint256 contractId,
        externalEuint64 encDeliveredTonnes, bytes calldata proof
    ) external nonReentrant {
        FeedstockContract storage c = contracts_[contractId];
        require(msg.sender == c.supplier || isQualityTester[msg.sender], "Not authorized");
        require(c.status == ContractStatus.Active, "Not active");
        euint64 delivered = FHE.fromExternal(encDeliveredTonnes, proof);
        c.deliveredTonnes = FHE.add(c.deliveredTonnes, delivered);
        FHE.allowThis(c.deliveredTonnes); FHE.allow(c.deliveredTonnes, c.supplier); FHE.allow(c.deliveredTonnes, c.energyProducer);
        emit DeliveryRecorded(contractId, block.timestamp);
    }

    function assessQualityPenalty(
        uint256 contractId,
        externalEuint64 encPenalty, bytes calldata proof
    ) external onlyQualityTester nonReentrant {
        FeedstockContract storage c = contracts_[contractId];
        euint64 penalty = FHE.fromExternal(encPenalty, proof);
        c.penaltiesAssessedUSD = FHE.add(c.penaltiesAssessedUSD, penalty);
        _totalPenaltiesUSD = FHE.add(_totalPenaltiesUSD, penalty);
        FHE.allowThis(c.penaltiesAssessedUSD); FHE.allow(c.penaltiesAssessedUSD, c.energyProducer); FHE.allow(c.penaltiesAssessedUSD, c.supplier);
        FHE.allowThis(_totalPenaltiesUSD);
        emit PenaltyAssessed(contractId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalContractValueUSD, viewer);
        FHE.allow(_totalPenaltiesUSD, viewer);
    }
}
