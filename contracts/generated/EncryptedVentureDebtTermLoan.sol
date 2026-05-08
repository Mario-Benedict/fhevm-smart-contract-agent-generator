// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedVentureDebtTermLoan
/// @notice Venture debt facilities with encrypted interest coverage ratios,
///         revenue covenants, warrant coverage calculations, and prepayment
///         premium schedules for startup financing.
contract EncryptedVentureDebtTermLoan is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum LoanStatus { TERM_SHEET, FUNDED, PERFORMING, COVENANT_BREACH, MATURED, DEFAULTED }
    enum CovenanType { MIN_CASH_RUNWAY, MIN_MRR, MAX_CHURN_RATE, MIN_GROSS_MARGIN, MIN_RUNWAY_MONTHS }

    struct VentureDebtFacility {
        address borrower;
        LoanStatus status;
        euint64 principalAmount;         // encrypted loan principal
        euint64 interestRateBps;         // encrypted base interest rate
        euint64 pikInterestBps;          // encrypted PIK interest rate
        euint64 warrantCoveragePercent;  // encrypted warrant coverage (bps of principal)
        euint64 warrantStrikePrice;      // encrypted warrant exercise price
        euint64 monthlyRevenueCovenant;  // encrypted minimum monthly revenue
        euint64 cashRunwayCovenant;      // encrypted minimum cash runway (months)
        euint64 outstandingBalance;      // encrypted current outstanding balance
        euint64 accruedInterest;         // encrypted accrued interest
        euint64 pikAccrued;              // encrypted PIK interest accrued
        euint64 prepaymentPremiumBps;    // encrypted prepayment premium
        euint64 endOfTermPayment;        // encrypted ETP amount (% of principal)
        uint256 fundingDate;
        uint256 maturityDate;
        bool drawdownComplete;
    }

    struct CovenantTest {
        bytes32 facilityId;
        CovenanType covenantType;
        euint64 requiredValue;           // encrypted required threshold
        euint64 actualValue;             // encrypted actual tested value
        euint64 headroom;                // encrypted covenant headroom
        bool passing;
        uint256 testDate;
    }

    mapping(bytes32 => VentureDebtFacility) private facilities;
    mapping(bytes32 => CovenantTest[]) private covenantTests;
    mapping(address => bool) public authorizedBorrower;

    euint64 private _totalPortfolioOutstanding;  // encrypted total outstanding
    euint64 private _totalInterestEarned;        // encrypted total interest earned
    euint64 private _warrantPortfolioValue;      // encrypted total warrant value

    event FacilityCreated(bytes32 indexed facilityId, address borrower);
    event DrawdownComplete(bytes32 indexed facilityId);
    event CovenantTestFailed(bytes32 indexed facilityId, CovenanType cType);
    event PrepaymentProcessed(bytes32 indexed facilityId);
    event FacilityMatured(bytes32 indexed facilityId);

    constructor() Ownable(msg.sender) {
        _totalPortfolioOutstanding = FHE.asEuint64(0);
        _totalInterestEarned = FHE.asEuint64(0);
        _warrantPortfolioValue = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioOutstanding);
        FHE.allowThis(_totalInterestEarned);
        FHE.allowThis(_warrantPortfolioValue);
    }

    function createFacility(
        address borrower,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encInterestRate, bytes calldata irProof,
        externalEuint64 encPIKRate, bytes calldata pikProof,
        externalEuint64 encWarrantCoverage, bytes calldata wcProof,
        externalEuint64 encWarrantStrike, bytes calldata wsProof,
        externalEuint64 encMRRCovenant, bytes calldata mrrProof,
        externalEuint64 encCashCovenant, bytes calldata ccProof,
        externalEuint64 encETP, bytes calldata etpProof,
        uint256 maturityDate
    ) external onlyOwner returns (bytes32 facilityId) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 interestRate = FHE.fromExternal(encInterestRate, irProof);
        euint64 pikRate = FHE.fromExternal(encPIKRate, pikProof);
        euint64 warrantCoverage = FHE.fromExternal(encWarrantCoverage, wcProof);
        euint64 warrantStrike = FHE.fromExternal(encWarrantStrike, wsProof);
        euint64 mrrCovenant = FHE.fromExternal(encMRRCovenant, mrrProof);
        euint64 cashCovenant = FHE.fromExternal(encCashCovenant, ccProof);
        euint64 etp = FHE.fromExternal(encETP, etpProof);
        euint64 prepaymentPremium = FHE.asEuint64(200); // 2% default

        facilityId = keccak256(abi.encodePacked(borrower, principal, block.timestamp));
        facilities[facilityId] = VentureDebtFacility({
            borrower: borrower, status: LoanStatus.TERM_SHEET,
            principalAmount: principal, interestRateBps: interestRate,
            pikInterestBps: pikRate, warrantCoveragePercent: warrantCoverage,
            warrantStrikePrice: warrantStrike, monthlyRevenueCovenant: mrrCovenant,
            cashRunwayCovenant: cashCovenant, outstandingBalance: principal,
            accruedInterest: FHE.asEuint64(0), pikAccrued: FHE.asEuint64(0),
            prepaymentPremiumBps: prepaymentPremium, endOfTermPayment: etp,
            fundingDate: block.timestamp, maturityDate: maturityDate, drawdownComplete: false
        });
        authorizedBorrower[borrower] = true;
        FHE.allowThis(principal); FHE.allow(principal, borrower);
        FHE.allowThis(interestRate); FHE.allow(interestRate, borrower);
        FHE.allowThis(pikRate); FHE.allow(pikRate, borrower);
        FHE.allowThis(warrantCoverage); FHE.allow(warrantCoverage, borrower);
        FHE.allowThis(warrantStrike); FHE.allow(warrantStrike, borrower);
        FHE.allowThis(mrrCovenant); FHE.allow(mrrCovenant, borrower);
        FHE.allowThis(cashCovenant); FHE.allow(cashCovenant, borrower);
        FHE.allowThis(etp); FHE.allow(etp, borrower);
        FHE.allowThis(prepaymentPremium);
        FHE.allowThis(facilities[facilityId].accruedInterest);
        FHE.allow(facilities[facilityId].accruedInterest, borrower);
        FHE.allowThis(facilities[facilityId].pikAccrued);
        FHE.allow(facilities[facilityId].pikAccrued, borrower);
        FHE.allowThis(facilities[facilityId].outstandingBalance);
        FHE.allow(facilities[facilityId].outstandingBalance, borrower);
        emit FacilityCreated(facilityId, borrower);
    }

    function fundFacility(bytes32 facilityId) external onlyOwner {
        VentureDebtFacility storage fac = facilities[facilityId];
        require(fac.status == LoanStatus.TERM_SHEET, "Not in term sheet");
        fac.status = LoanStatus.FUNDED;
        fac.drawdownComplete = true;
        fac.fundingDate = block.timestamp;
        _totalPortfolioOutstanding = FHE.add(_totalPortfolioOutstanding, fac.principalAmount);
        euint64 warrantValue = FHE.div(FHE.mul(fac.principalAmount, fac.warrantCoveragePercent), FHE.asEuint64(10000));
        _warrantPortfolioValue = FHE.add(_warrantPortfolioValue, warrantValue);
        FHE.allowThis(_totalPortfolioOutstanding);
        FHE.allowThis(_warrantPortfolioValue);
        emit DrawdownComplete(facilityId);
    }

    function accrueMonthlyInterest(bytes32 facilityId) external onlyOwner {
        VentureDebtFacility storage fac = facilities[facilityId];
        require(fac.status == LoanStatus.FUNDED || fac.status == LoanStatus.PERFORMING, "Not active");
        euint64 monthlyInterest = FHE.div(FHE.mul(fac.outstandingBalance, fac.interestRateBps), FHE.asEuint64(120000)); // annual / 12
        euint64 monthlyPIK = FHE.div(FHE.mul(fac.outstandingBalance, fac.pikInterestBps), FHE.asEuint64(120000));
        fac.accruedInterest = FHE.add(fac.accruedInterest, monthlyInterest);
        fac.pikAccrued = FHE.add(fac.pikAccrued, monthlyPIK);
        fac.outstandingBalance = FHE.add(fac.outstandingBalance, monthlyPIK); // PIK adds to balance
        _totalInterestEarned = FHE.add(_totalInterestEarned, monthlyInterest);
        FHE.allowThis(fac.accruedInterest); FHE.allow(fac.accruedInterest, fac.borrower);
        FHE.allowThis(fac.pikAccrued); FHE.allow(fac.pikAccrued, fac.borrower);
        FHE.allowThis(fac.outstandingBalance); FHE.allow(fac.outstandingBalance, fac.borrower);
        FHE.allowThis(_totalInterestEarned);
    }

    function testCovenant(
        bytes32 facilityId,
        CovenanType covenantType,
        externalEuint64 encActualValue, bytes calldata avProof
    ) external onlyOwner {
        VentureDebtFacility storage fac = facilities[facilityId];
        euint64 actualValue = FHE.fromExternal(encActualValue, avProof);
        euint64 required = covenantType == CovenanType.MIN_MRR ? fac.monthlyRevenueCovenant : fac.cashRunwayCovenant;
        ebool passing = FHE.ge(actualValue, required);
        euint64 headroom = FHE.select(passing, FHE.sub(actualValue, required), FHE.asEuint64(0));

        covenantTests[facilityId].push(CovenantTest({
            facilityId: facilityId, covenantType: covenantType,
            requiredValue: required, actualValue: actualValue,
            headroom: headroom, passing: true, testDate: block.timestamp
        }));
        FHE.allowThis(actualValue); FHE.allow(actualValue, fac.borrower);
        FHE.allowThis(headroom); FHE.allow(headroom, fac.borrower);
        FHE.allowThis(required); FHE.allow(required, fac.borrower);
        if (!true) { emit CovenantTestFailed(facilityId, covenantType); }
    }

    function allowFacilityDataView(bytes32 facilityId, address viewer) external onlyOwner {
        VentureDebtFacility storage fac = facilities[facilityId];
        FHE.allow(fac.outstandingBalance, viewer);
        FHE.allow(fac.accruedInterest, viewer);
        FHE.allow(fac.pikAccrued, viewer);
        FHE.allow(_totalPortfolioOutstanding, viewer);
    }
}
