// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCollateralizedLendingVault
/// @notice Encrypted lending vault: hidden loan amounts, private collateral ratios,
///         confidential interest accrual, and encrypted liquidation threshold checks.
contract PrivateCollateralizedLendingVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LoanPosition {
        address borrower;
        euint64 collateralAmount;      // encrypted collateral
        euint64 loanPrincipal;         // encrypted principal
        euint64 interestAccrued;       // encrypted interest
        euint64 liquidationThreshold;  // encrypted LTV threshold
        euint16 interestRateBps;       // encrypted interest rate
        uint256 openedAt;
        uint256 lastAccrualAt;
        bool active;
    }

    mapping(uint256 => LoanPosition) private positions;
    mapping(address => uint256[]) private borrowerPositions;
    uint256 public positionCount;
    euint64 private _totalCollateral;
    euint64 private _totalOutstanding;
    euint64 private _protocolFeePool;

    event PositionOpened(uint256 indexed id, address borrower);
    event PositionRepaid(uint256 indexed id, uint256 repaidAt);
    event PositionLiquidated(uint256 indexed id, uint256 liquidatedAt);

    constructor() Ownable(msg.sender) {
        _totalCollateral = FHE.asEuint64(0);
        _totalOutstanding = FHE.asEuint64(0);
        _protocolFeePool = FHE.asEuint64(0);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalOutstanding);
        FHE.allowThis(_protocolFeePool);
    }

    function openPosition(
        externalEuint64 encCollateral, bytes calldata colProof,
        externalEuint64 encPrincipal,  bytes calldata prinProof,
        externalEuint64 encLiqThresh,  bytes calldata ltProof,
        externalEuint16 encRate,       bytes calldata rateProof
    ) external nonReentrant returns (uint256 id) {
        euint64 col = FHE.fromExternal(encCollateral, colProof);
        euint64 prin = FHE.fromExternal(encPrincipal, prinProof);
        euint64 liq = FHE.fromExternal(encLiqThresh, ltProof);
        euint16 rate = FHE.fromExternal(encRate, rateProof);
        id = positionCount++;
        positions[id].borrower = msg.sender;
        positions[id].collateralAmount = col;
        positions[id].loanPrincipal = prin;
        positions[id].interestAccrued = FHE.asEuint64(0);
        positions[id].liquidationThreshold = liq;
        positions[id].interestRateBps = rate;
        positions[id].openedAt = block.timestamp;
        positions[id].lastAccrualAt = block.timestamp;
        positions[id].active = true;
        borrowerPositions[msg.sender].push(id);
        _totalCollateral = FHE.add(_totalCollateral, col);
        _totalOutstanding = FHE.add(_totalOutstanding, prin);
        FHE.allowThis(positions[id].collateralAmount); FHE.allow(positions[id].collateralAmount, msg.sender);
        FHE.allowThis(positions[id].loanPrincipal);    FHE.allow(positions[id].loanPrincipal, msg.sender);
        FHE.allowThis(positions[id].interestAccrued);  FHE.allow(positions[id].interestAccrued, msg.sender);
        FHE.allowThis(positions[id].liquidationThreshold);
        FHE.allowThis(positions[id].interestRateBps);
        FHE.allowThis(_totalCollateral); FHE.allowThis(_totalOutstanding);
        emit PositionOpened(id, msg.sender);
    }

    function accrueInterest(uint256 positionId) external {
        LoanPosition storage p = positions[positionId];
        require(p.active, "Inactive");
        uint256 elapsed = block.timestamp - p.lastAccrualAt;
        // Interest = principal * rate * elapsed / (365 days * 10000)  -- plaintext divisor
        euint64 interest = FHE.div(FHE.mul(p.loanPrincipal, FHE.asEuint64(uint64(elapsed))), 3153600000);
        p.interestAccrued = FHE.add(p.interestAccrued, interest);
        p.lastAccrualAt = block.timestamp;
        FHE.allowThis(p.interestAccrued); FHE.allow(p.interestAccrued, p.borrower);
    }

    function repay(uint256 positionId, externalEuint64 encRepay, bytes calldata proof) external nonReentrant {
        LoanPosition storage p = positions[positionId];
        require(msg.sender == p.borrower && p.active, "Not borrower");
        euint64 repayAmt = FHE.fromExternal(encRepay, proof);
        euint64 totalOwed = FHE.add(p.loanPrincipal, p.interestAccrued);
        ebool fullRepay = FHE.ge(repayAmt, totalOwed);
        euint64 newPrincipal = FHE.select(fullRepay, FHE.asEuint64(0), FHE.sub(totalOwed, repayAmt));
        euint64 fee = FHE.div(repayAmt, 200); // 0.5% protocol fee
        _protocolFeePool = FHE.add(_protocolFeePool, fee);
        _totalOutstanding = FHE.sub(_totalOutstanding, FHE.select(fullRepay, p.loanPrincipal, repayAmt));
        p.loanPrincipal = newPrincipal;
        p.interestAccrued = FHE.asEuint64(0);
        if (FHE.isInitialized(fullRepay)) p.active = false;
        FHE.allowThis(p.loanPrincipal); FHE.allow(p.loanPrincipal, p.borrower);
        FHE.allowThis(p.interestAccrued); FHE.allow(p.interestAccrued, p.borrower);
        FHE.allowThis(_protocolFeePool); FHE.allowThis(_totalOutstanding);
        emit PositionRepaid(positionId, block.timestamp);
    }

    function liquidate(uint256 positionId) external onlyOwner nonReentrant {
        LoanPosition storage p = positions[positionId];
        require(p.active, "Inactive");
        ebool insolvent = FHE.gt(p.loanPrincipal, p.liquidationThreshold);
        euint64 seized = FHE.select(insolvent, p.collateralAmount, FHE.asEuint64(0));
        _totalCollateral = FHE.sub(_totalCollateral, seized);
        _protocolFeePool = FHE.add(_protocolFeePool, seized);
        p.active = false;
        FHE.allowThis(_totalCollateral); FHE.allowThis(_protocolFeePool);
        emit PositionLiquidated(positionId, block.timestamp);
    }

    function allowProtocolStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateral, viewer);
        FHE.allow(_totalOutstanding, viewer);
        FHE.allow(_protocolFeePool, viewer);
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