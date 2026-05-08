// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDrugPricingNegotiation
/// @notice Pharmaceutical price negotiation between manufacturers and payers:
///         encrypted net price (after rebates), confidential utilization data,
///         and private outcomes-based contract calculations.
contract EncryptedDrugPricingNegotiation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum PricingModel { LIST_PRICE, NET_PRICE, OUTCOMES_BASED, VOLUME_DISCOUNT, VALUE_BASED }

    struct DrugContract {
        bytes32 ndcCode;              // NDC drug identifier
        address manufacturer;
        address payer;
        PricingModel model;
        euint64 listPricePerUnitUSD;  // encrypted WAC/list price
        euint64 netPricePerUnitUSD;   // encrypted contracted net price
        euint64 rebatePercentBps;     // encrypted rebate percentage
        euint64 volumeThresholdUnits; // encrypted volume trigger for discounts
        euint64 outcomesThresholdBps; // encrypted clinical outcome target
        euint64 outcomesRebateBps;    // encrypted extra rebate if target missed
        euint64 totalUnitsDispensed;  // encrypted utilization
        euint64 totalRebatesEarned;   // encrypted cumulative rebates
        uint256 contractStart;
        uint256 contractEnd;
        bool active;
    }

    struct OutcomesMeasurement {
        uint256 contractId;
        euint64 patientCohortSize;    // encrypted patient count
        euint64 responseRateBps;      // encrypted clinical response rate
        euint64 adverseEventRateBps;  // encrypted AE rate
        euint64 qualityAdjustedLifeYears; // encrypted QALY score
        euint64 rebateTriggerred;     // encrypted outcomes-based rebate
        uint256 measurementDate;
        bool adjudicated;
    }

    mapping(uint256 => DrugContract) private drugContracts;
    mapping(uint256 => OutcomesMeasurement) private outcomes;
    mapping(address => bool) public isManufacturer;
    mapping(address => bool) public isPayer;
    mapping(address => bool) public isClinicalAuditor;

    uint256 public contractCount;
    uint256 public outcomeCount;
    euint64 private _totalRebatePoolUSD;
    euint64 private _avgNetPriceReductionBps;

    event ContractNegotiated(uint256 indexed contractId, bytes32 ndcCode);
    event UtilizationReported(uint256 indexed contractId, uint256 period);
    event OutcomesSubmitted(uint256 indexed outcomeId, uint256 contractId);
    event RebateCalculated(uint256 indexed contractId, uint256 period);

    constructor() Ownable(msg.sender) {
        _totalRebatePoolUSD = FHE.asEuint64(0);
        _avgNetPriceReductionBps = FHE.asEuint64(0);
        FHE.allowThis(_totalRebatePoolUSD);
        FHE.allowThis(_avgNetPriceReductionBps);
        isManufacturer[msg.sender] = true;
        isPayer[msg.sender] = true;
        isClinicalAuditor[msg.sender] = true;
    }

    function negotiateContract(
        bytes32 ndcCode,
        address payer_,
        PricingModel model,
        externalEuint64 encListPrice, bytes calldata lpProof,
        externalEuint64 encNetPrice, bytes calldata npProof,
        externalEuint64 encRebate, bytes calldata rProof,
        externalEuint64 encVolThreshold, bytes calldata vtProof,
        externalEuint64 encOutcomesTarget, bytes calldata otProof,
        uint256 start, uint256 end
    ) external returns (uint256 contractId) {
        require(isManufacturer[msg.sender], "Not manufacturer");
        require(isPayer[payer_], "Not approved payer");
        euint64 listPrice = FHE.fromExternal(encListPrice, lpProof);
        euint64 netPrice = FHE.fromExternal(encNetPrice, npProof);
        euint64 rebate = FHE.fromExternal(encRebate, rProof);
        euint64 volThreshold = FHE.fromExternal(encVolThreshold, vtProof);
        euint64 outcomesTarget = FHE.fromExternal(encOutcomesTarget, otProof);
        contractId = contractCount++;
        DrugContract storage dc = drugContracts[contractId];
        dc.ndcCode = ndcCode;
        dc.manufacturer = msg.sender;
        dc.payer = payer_;
        dc.model = model;
        dc.listPricePerUnitUSD = listPrice;
        dc.netPricePerUnitUSD = netPrice;
        dc.rebatePercentBps = rebate;
        dc.volumeThresholdUnits = volThreshold;
        dc.outcomesThresholdBps = outcomesTarget;
        dc.outcomesRebateBps = FHE.asEuint64(500); // 5% additional rebate if outcomes missed
        dc.totalUnitsDispensed = FHE.asEuint64(0);
        dc.totalRebatesEarned = FHE.asEuint64(0);
        dc.contractStart = start;
        dc.contractEnd = end;
        dc.active = true;
        FHE.allowThis(dc.listPricePerUnitUSD);
        FHE.allow(dc.listPricePerUnitUSD, msg.sender);
        FHE.allow(dc.listPricePerUnitUSD, payer_);
        FHE.allowThis(dc.netPricePerUnitUSD);
        FHE.allow(dc.netPricePerUnitUSD, msg.sender);
        FHE.allow(dc.netPricePerUnitUSD, payer_);
        FHE.allowThis(dc.rebatePercentBps);
        FHE.allow(dc.rebatePercentBps, msg.sender);
        FHE.allow(dc.rebatePercentBps, payer_);
        FHE.allowThis(dc.totalUnitsDispensed);
        FHE.allowThis(dc.totalRebatesEarned);
        emit ContractNegotiated(contractId, ndcCode);
    }

    function reportUtilization(
        uint256 contractId,
        externalEuint64 encUnitsDispensed, bytes calldata udProof,
        uint256 period
    ) external {
        DrugContract storage dc = drugContracts[contractId];
        require(msg.sender == dc.payer, "Not payer");
        require(dc.active, "Contract not active");
        euint64 units = FHE.fromExternal(encUnitsDispensed, udProof);
        dc.totalUnitsDispensed = FHE.add(dc.totalUnitsDispensed, units);
        // Calculate base rebate
        euint64 grossRevenue = FHE.mul(units, dc.listPricePerUnitUSD);
        euint64 rebateAmount = FHE.div(FHE.mul(grossRevenue, dc.rebatePercentBps), 10000);
        // Volume discount: additional 2% if above threshold
        ebool aboveVolume = FHE.ge(dc.totalUnitsDispensed, dc.volumeThresholdUnits);
        euint64 volRebate = FHE.select(aboveVolume,
            FHE.div(FHE.mul(grossRevenue, 200), 10000), FHE.asEuint64(0));
        euint64 totalRebate = FHE.add(rebateAmount, volRebate);
        dc.totalRebatesEarned = FHE.add(dc.totalRebatesEarned, totalRebate);
        _totalRebatePoolUSD = FHE.add(_totalRebatePoolUSD, totalRebate);
        FHE.allowThis(dc.totalUnitsDispensed);
        FHE.allow(dc.totalUnitsDispensed, dc.manufacturer);
        FHE.allow(dc.totalUnitsDispensed, dc.payer);
        FHE.allowThis(dc.totalRebatesEarned);
        FHE.allow(dc.totalRebatesEarned, dc.payer);
        FHE.allow(dc.totalRebatesEarned, dc.manufacturer);
        FHE.allowThis(_totalRebatePoolUSD);
        emit UtilizationReported(contractId, period);
        emit RebateCalculated(contractId, period);
    }

    function submitOutcomes(
        uint256 contractId,
        externalEuint64 encCohortSize, bytes calldata csProof,
        externalEuint64 encResponseRate, bytes calldata rrProof,
        externalEuint64 encAERate, bytes calldata aerProof
    ) external returns (uint256 outcomeId) {
        require(isClinicalAuditor[msg.sender], "Not clinical auditor");
        DrugContract storage dc = drugContracts[contractId];
        euint64 cohortSize = FHE.fromExternal(encCohortSize, csProof);
        euint64 responseRate = FHE.fromExternal(encResponseRate, rrProof);
        euint64 aeRate = FHE.fromExternal(encAERate, aerProof);
        // Outcomes rebate: if response rate < threshold, trigger additional rebate
        ebool outcomesMissed = FHE.lt(responseRate, dc.outcomesThresholdBps);
        euint64 grossRev = FHE.mul(dc.totalUnitsDispensed, dc.listPricePerUnitUSD);
        euint64 outcomesRebate = FHE.select(outcomesMissed,
            FHE.div(FHE.mul(grossRev, dc.outcomesRebateBps), 10000), FHE.asEuint64(0));
        outcomeId = outcomeCount++;
        outcomes[outcomeId] = OutcomesMeasurement({
            contractId: contractId, patientCohortSize: cohortSize,
            responseRateBps: responseRate, adverseEventRateBps: aeRate,
            qualityAdjustedLifeYears: FHE.asEuint64(0), rebateTriggerred: outcomesRebate,
            measurementDate: block.timestamp, adjudicated: false
        });
        dc.totalRebatesEarned = FHE.add(dc.totalRebatesEarned, outcomesRebate);
        FHE.allowThis(outcomes[outcomeId].responseRateBps);
        FHE.allow(outcomes[outcomeId].responseRateBps, dc.manufacturer);
        FHE.allow(outcomes[outcomeId].responseRateBps, dc.payer);
        FHE.allowThis(outcomes[outcomeId].rebateTriggerred);
        FHE.allow(outcomes[outcomeId].rebateTriggerred, dc.payer);
        FHE.allowThis(dc.totalRebatesEarned);
        emit OutcomesSubmitted(outcomeId, contractId);
    }

    function addManufacturer(address m) external onlyOwner { isManufacturer[m] = true; }
    function addPayer(address p) external onlyOwner { isPayer[p] = true; }
    function addClinicalAuditor(address ca) external onlyOwner { isClinicalAuditor[ca] = true; }
    function allowRebateStats(address regulator) external onlyOwner {
        FHE.allow(_totalRebatePoolUSD, regulator);
    }
}
