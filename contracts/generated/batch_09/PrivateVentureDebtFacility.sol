// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateVentureDebtFacility
/// @notice Encrypted venture debt financing: hidden loan terms for startups, confidential
///         warrant coverage ratios, private revenue-based repayment schedules, and encrypted
///         IP collateral valuations for technology startups.
contract PrivateVentureDebtFacility is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum StartupStage { Seed, SeriesA, SeriesB, SeriesC, PreIPO }
    enum RepaymentType { BulletMaturity, RevenueBased, Amortizing }

    struct VentureDebtLoan {
        address startup;
        address debtLender;
        StartupStage stage;
        RepaymentType repaymentType;
        euint64 principalUSD;           // encrypted loan principal
        euint64 outstandingBalanceUSD;  // encrypted outstanding balance
        euint16 interestRateBps;        // encrypted annual interest rate
        euint16 warrantCoverageBps;     // encrypted warrant coverage ratio
        euint64 ipCollateralValueUSD;   // encrypted IP collateral value
        euint64 monthlyRevenueUSD;      // encrypted borrower monthly revenue
        euint16 revenueCapBps;          // encrypted revenue share cap bps
        euint64 totalRepaidUSD;         // encrypted total repaid
        uint256 disbursedAt;
        uint256 maturityDate;
    }

    mapping(uint256 => VentureDebtLoan) private loans;
    mapping(address => bool) public isVentureDebtFund;

    uint256 public loanCount;
    euint64 private _totalDeployedUSD;
    euint64 private _totalRepaidUSD;

    event LoanDisbursed(uint256 indexed id, StartupStage stage, RepaymentType repayType);
    event RevenueRepaymentMade(uint256 indexed loanId, uint256 madeAt);
    event LoanFullyRepaid(uint256 indexed loanId);

    modifier onlyVentureDebtFund() {
        require(isVentureDebtFund[msg.sender] || msg.sender == owner(), "Not venture debt fund");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDeployedUSD = FHE.asEuint64(0);
        _totalRepaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalDeployedUSD);
        FHE.allowThis(_totalRepaidUSD);
        isVentureDebtFund[msg.sender] = true;
    }

    function addVentureDebtFund(address f) external onlyOwner { isVentureDebtFund[f] = true; }

    function disburseLoan(
        address startup,
        StartupStage stage,
        RepaymentType repayType,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint16 encRate, bytes calldata rProof,
        externalEuint16 encWarrantCoverage, bytes calldata wcProof,
        externalEuint64 encIPCollateral, bytes calldata ipProof,
        externalEuint16 encRevCap, bytes calldata rcProof,
        uint256 maturityDays
    ) external onlyVentureDebtFund returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint16 rate = FHE.fromExternal(encRate, rProof);
        euint16 warrantCoverage = FHE.fromExternal(encWarrantCoverage, wcProof);
        euint64 ipCollateral = FHE.fromExternal(encIPCollateral, ipProof);
        euint16 revCap = FHE.fromExternal(encRevCap, rcProof);
        id = loanCount++;
        VentureDebtLoan storage _s0 = loans[id];
        _s0.startup = startup;
        _s0.debtLender = msg.sender;
        _s0.stage = stage;
        _s0.repaymentType = repayType;
        _s0.principalUSD = principal;
        _s0.outstandingBalanceUSD = principal;
        _s0.interestRateBps = rate;
        _s0.warrantCoverageBps = warrantCoverage;
        _s0.ipCollateralValueUSD = ipCollateral;
        _s0.monthlyRevenueUSD = FHE.asEuint64(0);
        _s0.revenueCapBps = revCap;
        _s0.totalRepaidUSD = FHE.asEuint64(0);
        _s0.disbursedAt = block.timestamp;
        _s0.maturityDate = block.timestamp + maturityDays * 1 days;
        _totalDeployedUSD = FHE.add(_totalDeployedUSD, principal);
        FHE.allowThis(loans[id].principalUSD); FHE.allow(loans[id].principalUSD, startup); FHE.allow(loans[id].principalUSD, msg.sender);
        FHE.allowThis(loans[id].outstandingBalanceUSD); FHE.allow(loans[id].outstandingBalanceUSD, startup);
        FHE.allowThis(loans[id].interestRateBps); FHE.allow(loans[id].interestRateBps, startup);
        FHE.allowThis(loans[id].warrantCoverageBps);
        FHE.allowThis(loans[id].ipCollateralValueUSD); FHE.allow(loans[id].ipCollateralValueUSD, msg.sender);
        FHE.allowThis(loans[id].monthlyRevenueUSD);
        FHE.allowThis(loans[id].revenueCapBps); FHE.allow(loans[id].revenueCapBps, startup);
        FHE.allowThis(loans[id].totalRepaidUSD); FHE.allow(loans[id].totalRepaidUSD, startup);
        FHE.allowThis(_totalDeployedUSD);
        emit LoanDisbursed(id, stage, repayType);
    }

    function makeRevenueRepayment(
        uint256 loanId,
        externalEuint64 encMonthlyRevenue, bytes calldata mrProof,
        externalEuint64 encRepayAmt, bytes calldata raProof
    ) external nonReentrant {
        VentureDebtLoan storage l = loans[loanId];
        require(msg.sender == l.startup, "Not borrower startup");
        euint64 monthlyRevenue = FHE.fromExternal(encMonthlyRevenue, mrProof);
        euint64 repayAmt = FHE.fromExternal(encRepayAmt, raProof);
        l.monthlyRevenueUSD = monthlyRevenue;
        ebool sufficientBalance = FHE.ge(l.outstandingBalanceUSD, repayAmt);
        euint64 appliedRepay = FHE.select(sufficientBalance, repayAmt, l.outstandingBalanceUSD);
        l.outstandingBalanceUSD = FHE.sub(l.outstandingBalanceUSD, appliedRepay);
        l.totalRepaidUSD = FHE.add(l.totalRepaidUSD, appliedRepay);
        _totalRepaidUSD = FHE.add(_totalRepaidUSD, appliedRepay);
        FHE.allowThis(l.monthlyRevenueUSD); FHE.allow(l.monthlyRevenueUSD, l.debtLender);
        FHE.allowThis(l.outstandingBalanceUSD); FHE.allow(l.outstandingBalanceUSD, l.startup); FHE.allow(l.outstandingBalanceUSD, l.debtLender);
        FHE.allowThis(l.totalRepaidUSD); FHE.allow(l.totalRepaidUSD, l.startup);
        FHE.allowThis(_totalRepaidUSD);
        emit RevenueRepaymentMade(loanId, block.timestamp);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalDeployedUSD, viewer);
        FHE.allow(_totalRepaidUSD, viewer);
    }
}
