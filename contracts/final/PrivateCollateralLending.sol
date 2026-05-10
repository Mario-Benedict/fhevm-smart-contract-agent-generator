// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCollateralLending - DeFi lending with encrypted collateral ratios and private loan terms
contract PrivateCollateralLending is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LoanPosition {
        euint64 collateralAmount;
        euint64 loanAmount;
        euint64 interestAccrued;
        euint64 collateralRatioBps; // e.g. 15000 = 150%
        uint256 openedAt;
        bool active;
        bool liquidated;
    }

    mapping(address => LoanPosition) private positions;
    euint64 private _totalCollateral;
    euint64 private _totalLoaned;
    euint64 private _liquidationThresholdBps; // encrypted, e.g. 12000 = 120%
    euint64 private _interestRateBpsPerYear;
    address[] public borrowers;

    event PositionOpened(address indexed borrower);
    event PositionClosed(address indexed borrower);
    event Liquidated(address indexed borrower);

    constructor(externalEuint64 encLiqThreshold, bytes memory ltProof,
                externalEuint64 encInterestRate, bytes memory irProof) Ownable(msg.sender) {
        _liquidationThresholdBps = FHE.fromExternal(encLiqThreshold, ltProof);
        _interestRateBpsPerYear = FHE.fromExternal(encInterestRate, irProof);
        _totalCollateral = FHE.asEuint64(0);
        _totalLoaned = FHE.asEuint64(0);
        FHE.allowThis(_liquidationThresholdBps);
        FHE.allowThis(_interestRateBpsPerYear);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalLoaned);
    }

    function depositCollateralAndBorrow(
        externalEuint64 encCollateral, bytes calldata cProof,
        externalEuint64 encLoan, bytes calldata lProof
    ) external nonReentrant {
        require(!positions[msg.sender].active, "Position exists");
        euint64 collateral = FHE.fromExternal(encCollateral, cProof);
        euint64 loan = FHE.fromExternal(encLoan, lProof);
        // Require collateral >= loan * liquidationThreshold / 10000
        euint64 minCollateral = FHE.div(FHE.mul(loan, _liquidationThresholdBps), 10000);
        ebool safeRatio = FHE.ge(collateral, minCollateral);
        euint64 actualLoan = FHE.select(safeRatio, loan, FHE.asEuint64(0));
        positions[msg.sender] = LoanPosition({
            collateralAmount: collateral, loanAmount: actualLoan,
            interestAccrued: FHE.asEuint64(0),
            collateralRatioBps: _liquidationThresholdBps,
            openedAt: block.timestamp, active: true, liquidated: false
        });
        _totalCollateral = FHE.add(_totalCollateral, collateral);
        _totalLoaned = FHE.add(_totalLoaned, actualLoan);
        FHE.allowThis(positions[msg.sender].collateralAmount);
        FHE.allow(positions[msg.sender].collateralAmount, msg.sender);
        FHE.allowThis(positions[msg.sender].loanAmount);
        FHE.allow(positions[msg.sender].loanAmount, msg.sender);
        FHE.allowThis(positions[msg.sender].interestAccrued);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalLoaned);
        FHE.allow(actualLoan, msg.sender);
        borrowers.push(msg.sender);
        emit PositionOpened(msg.sender);
    }

    function accrueInterest(address borrower) external {
        LoanPosition storage p = positions[borrower];
        require(p.active && !p.liquidated, "Invalid");
        uint256 yearsElapsed = (block.timestamp - p.openedAt) / 365 days;
        euint64 interest = FHE.div(
            FHE.mul(FHE.mul(p.loanAmount, _interestRateBpsPerYear), FHE.asEuint64(uint64(yearsElapsed))),
            10000
        );
        p.interestAccrued = FHE.add(p.interestAccrued, interest);
        FHE.allowThis(p.interestAccrued);
        FHE.allow(p.interestAccrued, borrower);
    }

    function repayAndClose(externalEuint64 encRepay, bytes calldata proof) external nonReentrant {
        LoanPosition storage p = positions[msg.sender];
        require(p.active && !p.liquidated, "Invalid");
        euint64 repay = FHE.fromExternal(encRepay, proof);
        euint64 totalOwed = FHE.add(p.loanAmount, p.interestAccrued);
        ebool fullRepay = FHE.ge(repay, totalOwed);
        euint64 collateralReturn = FHE.select(fullRepay, p.collateralAmount, FHE.asEuint64(0));
        p.active = FHE.isInitialized(fullRepay) ? false : p.active;
        _totalCollateral = FHE.sub(_totalCollateral, collateralReturn);
        _totalLoaned = FHE.sub(_totalLoaned, p.loanAmount);
        FHE.allowThis(_totalCollateral); FHE.allowThis(_totalLoaned);
        FHE.allow(collateralReturn, msg.sender);
        emit PositionClosed(msg.sender);
    }

    function liquidate(address borrower, externalEuint64 encCurrentPrice, bytes calldata proof) external onlyOwner {
        LoanPosition storage p = positions[borrower];
        require(p.active && !p.liquidated, "Invalid");
        euint64 currentPrice = FHE.fromExternal(encCurrentPrice, proof);
        euint64 collateralValue = FHE.mul(p.collateralAmount, currentPrice);
        euint64 requiredValue = FHE.div(FHE.mul(p.loanAmount, _liquidationThresholdBps), 10000);
        ebool undercollateralized = FHE.lt(collateralValue, requiredValue);
        if (FHE.isInitialized(undercollateralized)) {
            p.liquidated = true;
            p.active = false;
            FHE.allow(p.collateralAmount, owner());
            emit Liquidated(borrower);
        }
    }

    function allowPosition(address viewer) external {
        FHE.allow(positions[msg.sender].collateralAmount, viewer);
        FHE.allow(positions[msg.sender].loanAmount, viewer);
        FHE.allow(positions[msg.sender].interestAccrued, viewer);
    }

    function allowProtocolStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateral, viewer);
        FHE.allow(_totalLoaned, viewer);
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