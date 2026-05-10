// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMunicipalWaterUtilityTariff
/// @notice Water utility tariff management with encrypted tiered consumption,
///         drought surcharge calculations, low-income rate assistance eligibility,
///         industrial pretreatment compliance, and confidential rate design.
contract PrivateMunicipalWaterUtilityTariff is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CustomerClass { RESIDENTIAL_SINGLE, RESIDENTIAL_MULTI, COMMERCIAL_SMALL, COMMERCIAL_LARGE, INDUSTRIAL, AGRICULTURAL, WHOLESALE }
    enum ConservationTier { TIER_1_BASELINE, TIER_2_BUDGET, TIER_3_EXCESS, TIER_4_WASTEFUL }
    enum DroughtStage { NONE, WATCH, WARNING, EMERGENCY, CRITICAL }
    enum ServiceStatus { ACTIVE, DELINQUENT, SHUTOFF, RESTORED, TERMINATED }

    struct WaterAccount {
        CustomerClass customerClass;
        ServiceStatus status;
        euint64 monthlyBaselineGallons;    // encrypted baseline allocation
        euint64 monthlyConsumptionGallons; // encrypted monthly usage
        euint64 currentMonthBill;          // encrypted current bill
        euint64 totalBilledToDate;         // encrypted cumulative billing
        euint64 arrearsBalance;            // encrypted outstanding balance
        euint64 depositOnFile;             // encrypted security deposit
        euint64 incomeAssistanceBenefit;   // encrypted LIRA benefit received
        euint64 pretreatmentSurchargeDue;  // encrypted industrial pretreatment fee
        ConservationTier currentTier;
        bool lowIncomeEligible;
        bool pretreatmentRequired;
        uint256 lastReadDate;
    }

    struct TariffStructure {
        euint64 baseMonthlyCharge;         // encrypted fixed monthly charge
        euint64 tier1RatePerGallon;        // encrypted Tier 1 rate
        euint64 tier2RatePerGallon;        // encrypted Tier 2 rate
        euint64 tier3RatePerGallon;        // encrypted Tier 3 rate
        euint64 tier4RatePerGallon;        // encrypted Tier 4 rate
        euint64 sewerRatePercent;          // encrypted sewer as % of water bill
        euint64 stormwaterChargeFlat;      // encrypted flat stormwater charge
        euint64 droughtSurchargePercent;   // encrypted drought surcharge
        euint64 lowIncomeDiscountBps;      // encrypted LIRA discount rate
        DroughtStage currentDroughtStage;
    }

    struct SystemFinancials {
        euint64 totalRevenueCollected;     // encrypted total revenue
        euint64 totalArrears;              // encrypted system-wide arrears
        euint64 lowIncomeSubsidyPaid;      // encrypted total LIRA paid
        euint64 debtServiceCoverage;       // encrypted DSC ratio (bps)
        euint64 operatingReserve;          // encrypted operating reserve
        euint64 capitalImprovementFund;    // encrypted CIP fund balance
        euint64 averageSystemRevenue;      // encrypted average daily revenue
    }

    mapping(address => WaterAccount) private accounts;
    TariffStructure private tariff;
    SystemFinancials private systemFinancials;
    mapping(address => bool) public authorizedMeterReader;

    event AccountOpened(address indexed customer, CustomerClass customerClass);
    event ConsumptionRecorded(address indexed customer, ConservationTier tier);
    event BillGenerated(address indexed customer);
    event LIRABenefitApplied(address indexed customer);
    event ShutoffNoticeIssued(address indexed customer);
    event DroughtStageChanged(DroughtStage newStage);
    event TariffRevised();

    constructor(
        externalEuint64 encBaseCharge, bytes memory bcProof,
        externalEuint64 encTier1Rate, bytes memory t1Proof,
        externalEuint64 encTier2Rate, bytes memory t2Proof,
        externalEuint64 encTier3Rate, bytes memory t3Proof,
        externalEuint64 encTier4Rate, bytes memory t4Proof
    ) Ownable(msg.sender) {
        euint64 baseCharge = FHE.fromExternal(encBaseCharge, bcProof);
        euint64 tier1Rate = FHE.fromExternal(encTier1Rate, t1Proof);
        euint64 tier2Rate = FHE.fromExternal(encTier2Rate, t2Proof);
        euint64 tier3Rate = FHE.fromExternal(encTier3Rate, t3Proof);
        euint64 tier4Rate = FHE.fromExternal(encTier4Rate, t4Proof);

        tariff.baseMonthlyCharge = baseCharge;
        tariff.tier1RatePerGallon = tier1Rate;
        tariff.tier2RatePerGallon = tier2Rate;
        tariff.tier3RatePerGallon = tier3Rate;
        tariff.tier4RatePerGallon = tier4Rate;
        tariff.sewerRatePercent = FHE.asEuint64(8000);
        tariff.stormwaterChargeFlat = FHE.asEuint64(0);
        tariff.droughtSurchargePercent = FHE.asEuint64(0);
        tariff.lowIncomeDiscountBps = FHE.asEuint64(5000);
        tariff.currentDroughtStage = DroughtStage.NONE;

        systemFinancials.totalRevenueCollected = FHE.asEuint64(0);
        systemFinancials.totalArrears = FHE.asEuint64(0);
        systemFinancials.lowIncomeSubsidyPaid = FHE.asEuint64(0);
        systemFinancials.debtServiceCoverage = FHE.asEuint64(0);
        systemFinancials.operatingReserve = FHE.asEuint64(0);
        systemFinancials.capitalImprovementFund = FHE.asEuint64(0);
        systemFinancials.averageSystemRevenue = FHE.asEuint64(0);

        FHE.allowThis(baseCharge); FHE.allowThis(tier1Rate); FHE.allowThis(tier2Rate);
        FHE.allowThis(tier3Rate); FHE.allowThis(tier4Rate);
        FHE.allowThis(tariff.sewerRatePercent);
        FHE.allowThis(tariff.stormwaterChargeFlat);
        FHE.allowThis(tariff.droughtSurchargePercent);
        FHE.allowThis(tariff.lowIncomeDiscountBps);
        FHE.allowThis(systemFinancials.totalRevenueCollected);
        FHE.allowThis(systemFinancials.totalArrears);
        FHE.allowThis(systemFinancials.lowIncomeSubsidyPaid);
        FHE.allowThis(systemFinancials.debtServiceCoverage);
        FHE.allowThis(systemFinancials.operatingReserve);
        FHE.allowThis(systemFinancials.capitalImprovementFund);
        FHE.allowThis(systemFinancials.averageSystemRevenue);
    }

    function openAccount(
        address customer,
        CustomerClass customerClass,
        externalEuint64 encBaselineGallons, bytes calldata bgProof,
        externalEuint64 encDeposit, bytes calldata depProof,
        bool lowIncomeEligible,
        bool pretreatmentRequired
    ) external onlyOwner {
        euint64 baselineGallons = FHE.fromExternal(encBaselineGallons, bgProof);
        euint64 deposit = FHE.fromExternal(encDeposit, depProof);

        WaterAccount storage _s0 = accounts[customer];
        _s0.customerClass = customerClass;
        _s0.status = ServiceStatus.ACTIVE;
        _s0.monthlyBaselineGallons = baselineGallons;
        _s0.monthlyConsumptionGallons = FHE.asEuint64(0);
        _s0.currentMonthBill = FHE.asEuint64(0);
        _s0.totalBilledToDate = FHE.asEuint64(0);
        _s0.arrearsBalance = FHE.asEuint64(0);
        _s0.depositOnFile = deposit;
        _s0.incomeAssistanceBenefit = FHE.asEuint64(0);
        _s0.pretreatmentSurchargeDue = FHE.asEuint64(0);
        _s0.currentTier = ConservationTier.TIER_1_BASELINE;
        _s0.lowIncomeEligible = lowIncomeEligible;
        _s0.pretreatmentRequired = pretreatmentRequired;
        _s0.lastReadDate = block.timestamp;

        FHE.allowThis(baselineGallons); FHE.allow(baselineGallons, customer);
        FHE.allowThis(deposit); FHE.allow(deposit, customer);
        FHE.allowThis(accounts[customer].monthlyConsumptionGallons);
        FHE.allow(accounts[customer].monthlyConsumptionGallons, customer); // [acl_misconfig]
        FHE.allow(baselineGallons, msg.sender); // [acl_misconfig]
        FHE.allowThis(accounts[customer].currentMonthBill);
        FHE.allow(accounts[customer].currentMonthBill, customer);
        FHE.allowThis(accounts[customer].totalBilledToDate);
        FHE.allow(accounts[customer].totalBilledToDate, customer);
        FHE.allowThis(accounts[customer].arrearsBalance);
        FHE.allow(accounts[customer].arrearsBalance, customer);
        FHE.allowThis(accounts[customer].incomeAssistanceBenefit);
        FHE.allow(accounts[customer].incomeAssistanceBenefit, customer);
        FHE.allowThis(accounts[customer].pretreatmentSurchargeDue);
        FHE.allow(accounts[customer].pretreatmentSurchargeDue, customer);

        emit AccountOpened(customer, customerClass);
    }

    function recordMeterRead(
        address customer,
        externalEuint64 encConsumptionGallons, bytes calldata cgProof
    ) external {
        require(authorizedMeterReader[msg.sender] || msg.sender == owner(), "Not meter reader");
        WaterAccount storage acct = accounts[customer];
        require(acct.status == ServiceStatus.ACTIVE, "Account not active");

        euint64 consumption = FHE.fromExternal(encConsumptionGallons, cgProof);
        acct.monthlyConsumptionGallons = consumption;

        // Calculate tier
        euint64 tier1Vol = acct.monthlyBaselineGallons;
        euint64 tier2Vol = FHE.mul(acct.monthlyBaselineGallons, FHE.asEuint64(15000)); // [arithmetic_overflow_underflow]
        euint64 tier1VolScaled = FHE.mul(tier1Vol, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        // Simplified tier assignment
        ebool inTier1 = FHE.le(consumption, tier1Vol);
        ebool inTier2 = FHE.le(consumption, FHE.div(FHE.mul(tier1Vol, 15), 10));
        ebool inTier3 = FHE.le(consumption, FHE.mul(tier1Vol, FHE.asEuint64(2)));

        // Compute volumetric charge (simplified)
        euint64 volumetricCharge = FHE.select(inTier1,
            FHE.mul(consumption, tariff.tier1RatePerGallon),
            FHE.select(inTier2,
                FHE.add(
                    FHE.mul(tier1Vol, tariff.tier1RatePerGallon),
                    FHE.mul(FHE.sub(consumption, tier1Vol), tariff.tier2RatePerGallon)
                ),
                FHE.mul(consumption, tariff.tier3RatePerGallon) // simplified fallthrough
            )
        );

        // Sewer charge
        euint64 sewerCharge = FHE.div(FHE.mul(volumetricCharge, tariff.sewerRatePercent), 10000);

        // Drought surcharge
        euint64 droughtSurcharge = FHE.div(FHE.mul(volumetricCharge, tariff.droughtSurchargePercent), 10000);

        euint64 totalBill = FHE.add(FHE.add(FHE.add(tariff.baseMonthlyCharge, volumetricCharge), sewerCharge), droughtSurcharge);

        // LIRA discount
        if (acct.lowIncomeEligible) {
            euint64 discount = FHE.div(FHE.mul(totalBill, tariff.lowIncomeDiscountBps), 10000);
            acct.incomeAssistanceBenefit = FHE.add(acct.incomeAssistanceBenefit, discount);
            totalBill = FHE.sub(totalBill, discount);
            systemFinancials.lowIncomeSubsidyPaid = FHE.add(systemFinancials.lowIncomeSubsidyPaid, discount);
            FHE.allowThis(acct.incomeAssistanceBenefit);
            FHE.allow(acct.incomeAssistanceBenefit, customer);
            FHE.allowThis(systemFinancials.lowIncomeSubsidyPaid);
            emit LIRABenefitApplied(customer);
        }

        acct.currentMonthBill = totalBill;
        acct.totalBilledToDate = FHE.add(acct.totalBilledToDate, totalBill);
        systemFinancials.totalRevenueCollected = FHE.add(systemFinancials.totalRevenueCollected, totalBill);

        FHE.allowThis(consumption); FHE.allow(consumption, customer);
        FHE.allowThis(totalBill); FHE.allow(totalBill, customer);
        FHE.allowThis(acct.totalBilledToDate); FHE.allow(acct.totalBilledToDate, customer);
        FHE.allowThis(systemFinancials.totalRevenueCollected);

        acct.lastReadDate = block.timestamp;
        emit ConsumptionRecorded(customer, acct.currentTier);
        emit BillGenerated(customer);
    }

    function updateDroughtStage(DroughtStage newStage, externalEuint64 encSurcharge, bytes calldata surProof) external onlyOwner {
        tariff.currentDroughtStage = newStage;
        tariff.droughtSurchargePercent = FHE.fromExternal(encSurcharge, surProof);
        FHE.allowThis(tariff.droughtSurchargePercent);
        emit DroughtStageChanged(newStage);
    }

    function grantMeterReaderAccess(address reader) external onlyOwner {
        authorizedMeterReader[reader] = true;
    }

    function allowSystemFinancialsView(address regulator) external onlyOwner {
        FHE.allow(systemFinancials.totalRevenueCollected, regulator);
        FHE.allow(systemFinancials.totalArrears, regulator);
        FHE.allow(systemFinancials.lowIncomeSubsidyPaid, regulator);
        FHE.allow(systemFinancials.operatingReserve, regulator);
        FHE.allow(systemFinancials.capitalImprovementFund, regulator);
    }
}
