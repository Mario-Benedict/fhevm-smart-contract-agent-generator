// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedElderCareHomePlacementFund
/// @notice Elder care placement with encrypted Medicaid spend-down calculations,
///         private room supplement pricing, family contribution assessments,
///         and estate recovery lien tracking.
contract EncryptedElderCareHomePlacementFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CareLevel { INDEPENDENT_LIVING, ASSISTED_LIVING, MEMORY_CARE, SKILLED_NURSING, HOSPICE }
    enum PayorType { PRIVATE_PAY, MEDICAID, MEDICARE, LONG_TERM_CARE_INSURANCE, VA_BENEFITS, MIXED }
    enum AdmissionStatus { WAITLISTED, ADMITTED, TRANSFERRED, DISCHARGED, DECEASED }

    struct Resident {
        bytes32 residentToken;
        CareLevel careLevel;
        PayorType payorType;
        AdmissionStatus status;
        euint64 monthlyPrivatePayRate;      // encrypted private room rate
        euint64 monthlyMedicaidRate;        // encrypted Medicaid reimbursement rate
        euint64 privatePaySupplement;       // encrypted supplement (private - Medicaid)
        euint64 assetsAtAdmission;          // encrypted total assets at admission
        euint64 currentAssets;              // encrypted current remaining assets
        euint64 spendDownTarget;            // encrypted Medicaid eligibility threshold
        euint64 monthlyFamilyContribution;  // encrypted family share of cost
        euint64 totalBilledToDate;          // encrypted cumulative billing
        euint64 medicaidLienAmount;         // encrypted estate recovery lien
        euint64 longTermCareInsuranceBenefit; // encrypted LTCI daily benefit
        uint256 admittedAt;
        uint256 medicaidConversionDate;
        bool medicaidEligible;
    }

    struct FacilityFinancials {
        euint64 monthlyPrivateRevenue;      // encrypted private pay revenue
        euint64 monthlyMedicaidRevenue;     // encrypted Medicaid revenue
        euint64 monthlyMedicareRevenue;     // encrypted Medicare revenue
        euint64 totalUncompensatedCare;     // encrypted charity/bad debt
        euint64 medicaidPendingReceivable;  // encrypted pending Medicaid AR
        euint64 occupancyRevenueCap;        // encrypted max capacity revenue
        euint16 totalBeds;                  // encrypted total bed count
        euint16 occupiedBeds;               // encrypted occupied beds
        euint16 medicaidCertifiedBeds;      // encrypted Medicaid-certified beds
    }

    mapping(bytes32 => Resident) private residents;
    FacilityFinancials private financials;
    mapping(address => bool) public authorizedSocialWorker;
    mapping(address => bool) public authorizedBillingAdmin;

    euint64 private _totalEstateRecoveryPool;    // encrypted estate recovery collected
    euint64 private _totalLTCIClaimsSubmitted;   // encrypted LTCI claims total

    event ResidentAdmitted(bytes32 indexed residentToken, CareLevel level, PayorType payor);
    event MedicaidConversionApproved(bytes32 indexed residentToken);
    event SpendDownMilestoneReached(bytes32 indexed residentToken);
    event EstateLienFiled(bytes32 indexed residentToken);
    event MonthlyBillingProcessed(bytes32 indexed residentToken);
    event ResidentDischarged(bytes32 indexed residentToken, AdmissionStatus status);

    constructor(
        externalEuint16 encTotalBeds, bytes memory tbProof,
        externalEuint16 encMedicaidBeds, bytes memory mbProof
    ) Ownable(msg.sender) {
        euint16 totalBeds = FHE.fromExternal(encTotalBeds, tbProof);
        euint16 medicaidBeds = FHE.fromExternal(encMedicaidBeds, mbProof);
        financials = FacilityFinancials({
            monthlyPrivateRevenue: FHE.asEuint64(0),
            monthlyMedicaidRevenue: FHE.asEuint64(0),
            monthlyMedicareRevenue: FHE.asEuint64(0),
            totalUncompensatedCare: FHE.asEuint64(0),
            medicaidPendingReceivable: FHE.asEuint64(0),
            occupancyRevenueCap: FHE.asEuint64(0),
            totalBeds: totalBeds,
            occupiedBeds: FHE.asEuint16(0),
            medicaidCertifiedBeds: medicaidBeds
        });
        _totalEstateRecoveryPool = FHE.asEuint64(0);
        _totalLTCIClaimsSubmitted = FHE.asEuint64(0);
        FHE.allowThis(totalBeds); FHE.allowThis(medicaidBeds);
        FHE.allowThis(financials.monthlyPrivateRevenue);
        FHE.allowThis(financials.monthlyMedicaidRevenue);
        FHE.allowThis(financials.monthlyMedicareRevenue);
        FHE.allowThis(financials.totalUncompensatedCare);
        FHE.allowThis(financials.medicaidPendingReceivable);
        FHE.allowThis(financials.occupancyRevenueCap);
        FHE.allowThis(financials.occupiedBeds);
        FHE.allowThis(_totalEstateRecoveryPool);
        FHE.allowThis(_totalLTCIClaimsSubmitted);
    }

    modifier onlySocialWorker() {
        require(authorizedSocialWorker[msg.sender] || msg.sender == owner(), "Not social worker");
        _;
    }

    modifier onlyBilling() {
        require(authorizedBillingAdmin[msg.sender] || msg.sender == owner(), "Not billing");
        _;
    }

    function grantSocialWorkerAccess(address sw) external onlyOwner {
        authorizedSocialWorker[sw] = true;
    }

    function grantBillingAccess(address billing) external onlyOwner {
        authorizedBillingAdmin[billing] = true;
    }

    function admitResident(
        bytes32 residentToken,
        CareLevel careLevel,
        PayorType payorType,
        externalEuint64 encPrivateRate, bytes calldata prProof,
        externalEuint64 encMedicaidRate, bytes calldata mrProof,
        externalEuint64 encTotalAssets, bytes calldata taProof,
        externalEuint64 encSpendDownTarget, bytes calldata sdProof,
        externalEuint64 encFamilyContribution, bytes calldata fcProof,
        externalEuint64 encLTCIBenefit, bytes calldata ltciProof
    ) external onlySocialWorker nonReentrant {
        require(residents[residentToken].admittedAt == 0, "Already admitted");

        euint64 privateRate = FHE.fromExternal(encPrivateRate, prProof);
        euint64 medicaidRate = FHE.fromExternal(encMedicaidRate, mrProof);
        euint64 totalAssets = FHE.fromExternal(encTotalAssets, taProof);
        euint64 spendDownTarget = FHE.fromExternal(encSpendDownTarget, sdProof);
        euint64 familyContribution = FHE.fromExternal(encFamilyContribution, fcProof);
        euint64 ltciBenefit = FHE.fromExternal(encLTCIBenefit, ltciProof);

        ebool privateGreater = FHE.ge(privateRate, medicaidRate);
        euint64 supplement = FHE.select(privateGreater,
            FHE.sub(privateRate, medicaidRate),
            FHE.asEuint64(0));

        residents[residentToken] = Resident({
            residentToken: residentToken,
            careLevel: careLevel,
            payorType: payorType,
            status: AdmissionStatus.ADMITTED,
            monthlyPrivatePayRate: privateRate,
            monthlyMedicaidRate: medicaidRate,
            privatePaySupplement: supplement,
            assetsAtAdmission: totalAssets,
            currentAssets: totalAssets,
            spendDownTarget: spendDownTarget,
            monthlyFamilyContribution: familyContribution,
            totalBilledToDate: FHE.asEuint64(0),
            medicaidLienAmount: FHE.asEuint64(0),
            longTermCareInsuranceBenefit: ltciBenefit,
            admittedAt: block.timestamp,
            medicaidConversionDate: 0,
            medicaidEligible: false
        });

        financials.occupiedBeds = FHE.add(financials.occupiedBeds, FHE.asEuint16(1));

        FHE.allowThis(privateRate); FHE.allow(privateRate, msg.sender);
        FHE.allowThis(medicaidRate); FHE.allow(medicaidRate, msg.sender);
        FHE.allowThis(totalAssets); FHE.allow(totalAssets, msg.sender);
        FHE.allowThis(spendDownTarget); FHE.allow(spendDownTarget, msg.sender);
        FHE.allowThis(familyContribution); FHE.allow(familyContribution, msg.sender);
        FHE.allowThis(ltciBenefit); FHE.allow(ltciBenefit, msg.sender);
        FHE.allowThis(supplement);
        FHE.allowThis(residents[residentToken].totalBilledToDate);
        FHE.allow(residents[residentToken].totalBilledToDate, msg.sender);
        FHE.allowThis(residents[residentToken].medicaidLienAmount);
        FHE.allow(residents[residentToken].medicaidLienAmount, msg.sender);
        FHE.allowThis(financials.occupiedBeds);

        emit ResidentAdmitted(residentToken, careLevel, payorType);
    }

    function processMonthlyBilling(bytes32 residentToken) external onlyBilling {
        Resident storage r = residents[residentToken];
        require(r.status == AdmissionStatus.ADMITTED, "Not active");

        euint64 monthlyRate = r.medicaidEligible ? r.monthlyMedicaidRate : r.monthlyPrivatePayRate;
        euint64 netBilling = FHE.sub(monthlyRate,
            FHE.select(FHE.ge(monthlyRate, r.longTermCareInsuranceBenefit),
                r.longTermCareInsuranceBenefit,
                monthlyRate));

        r.totalBilledToDate = FHE.add(r.totalBilledToDate, monthlyRate);

        // Spend down: reduce assets by private pay amount
        if (!r.medicaidEligible) {
            euint64 oop = FHE.sub(monthlyRate,
                FHE.select(FHE.ge(monthlyRate, FHE.add(r.longTermCareInsuranceBenefit, r.monthlyFamilyContribution)),
                    FHE.add(r.longTermCareInsuranceBenefit, r.monthlyFamilyContribution),
                    monthlyRate));
            r.currentAssets = FHE.select(FHE.ge(r.currentAssets, oop),
                FHE.sub(r.currentAssets, oop),
                FHE.asEuint64(0));
            // Check if spend-down threshold reached
            ebool spendDownComplete = FHE.le(r.currentAssets, r.spendDownTarget);
            // If so: could trigger Medicaid conversion (owner/social worker handles)
            FHE.allowThis(r.currentAssets);
            FHE.allow(r.currentAssets, msg.sender);
        }

        if (r.medicaidEligible) {
            financials.monthlyMedicaidRevenue = FHE.add(financials.monthlyMedicaidRevenue, monthlyRate);
            FHE.allowThis(financials.monthlyMedicaidRevenue);
        } else {
            financials.monthlyPrivateRevenue = FHE.add(financials.monthlyPrivateRevenue, monthlyRate);
            FHE.allowThis(financials.monthlyPrivateRevenue);
        }

        _totalLTCIClaimsSubmitted = FHE.add(_totalLTCIClaimsSubmitted, r.longTermCareInsuranceBenefit);
        FHE.allowThis(_totalLTCIClaimsSubmitted);
        FHE.allowThis(r.totalBilledToDate);
        FHE.allow(r.totalBilledToDate, msg.sender);
        FHE.allowTransient(netBilling, msg.sender);

        emit MonthlyBillingProcessed(residentToken);
    }

    function approveMedicaidConversion(bytes32 residentToken) external onlySocialWorker {
        Resident storage r = residents[residentToken];
        require(!r.medicaidEligible, "Already Medicaid");
        r.medicaidEligible = true;
        r.medicaidConversionDate = block.timestamp;
        r.payorType = PayorType.MEDICAID;

        // Estate recovery lien = assets remaining above Medicaid threshold
        euint64 liableAssets = FHE.select(FHE.ge(r.currentAssets, r.spendDownTarget),
            FHE.sub(r.currentAssets, r.spendDownTarget),
            FHE.asEuint64(0));
        r.medicaidLienAmount = liableAssets;
        FHE.allowThis(r.medicaidLienAmount);
        FHE.allow(r.medicaidLienAmount, msg.sender);

        emit MedicaidConversionApproved(residentToken);
        if (FHE.asEuint64(0) != liableAssets) {
            emit EstateLienFiled(residentToken);
        }
    }

    function collectEstateLien(bytes32 residentToken) external onlyBilling {
        Resident storage r = residents[residentToken];
        require(r.status == AdmissionStatus.DECEASED || r.status == AdmissionStatus.DISCHARGED, "Still active");
        _totalEstateRecoveryPool = FHE.add(_totalEstateRecoveryPool, r.medicaidLienAmount);
        FHE.allowThis(_totalEstateRecoveryPool);
    }

    function allowResidentDataView(bytes32 residentToken, address viewer) external onlyBilling {
        Resident storage r = residents[residentToken];
        FHE.allow(r.monthlyPrivatePayRate, viewer);
        FHE.allow(r.currentAssets, viewer);
        FHE.allow(r.totalBilledToDate, viewer);
        FHE.allow(r.medicaidLienAmount, viewer);
        FHE.allow(r.monthlyFamilyContribution, viewer);
    }
}
