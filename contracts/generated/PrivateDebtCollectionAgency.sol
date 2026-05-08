// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateDebtCollectionAgency
/// @notice Debt collection with encrypted outstanding balances, encrypted collector commissions,
///         and private settlement negotiations between debtors and collectors.
contract PrivateDebtCollectionAgency is ZamaEthereumConfig, Ownable {
    enum DebtStatus { Active, InDispute, PartialSettlement, FullSettlement, WrittenOff }

    struct DebtAccount {
        address debtor;
        address originalCreditor;
        euint64 originalBalance;     // encrypted original debt
        euint64 currentBalance;      // encrypted remaining balance
        euint64 accruedInterest;     // encrypted interest accumulated
        euint64 commissionRateBps;   // encrypted collector commission
        uint256 purchasedAt;
        uint256 lastActivity;
        DebtStatus status;
        address collector;
    }

    mapping(uint256 => DebtAccount) private accounts;
    mapping(address => euint64) private _collectorEarnings;
    mapping(address => bool) public isCollector;
    uint256 public accountCount;
    euint64 private _totalDebtPortfolio;
    euint64 private _totalRecovered;

    event AccountPurchased(uint256 indexed id, address collector);
    event PaymentReceived(uint256 indexed id);
    event AccountSettled(uint256 indexed id, DebtStatus status);

    constructor() Ownable(msg.sender) {
        _totalDebtPortfolio = FHE.asEuint64(0);
        _totalRecovered = FHE.asEuint64(0);
        FHE.allowThis(_totalDebtPortfolio);
        FHE.allowThis(_totalRecovered);
        isCollector[msg.sender] = true;
    }

    function addCollector(address c) external onlyOwner { isCollector[c] = true; }

    function purchaseDebtAccount(
        address debtor,
        address originalCreditor,
        externalEuint64 encBalance, bytes calldata bProof,
        externalEuint64 encCommission, bytes calldata cProof
    ) external returns (uint256 id) {
        require(isCollector[msg.sender], "Not collector");
        euint64 balance = FHE.fromExternal(encBalance, bProof);
        euint64 commission = FHE.fromExternal(encCommission, cProof);
        id = accountCount++;
        accounts[id] = DebtAccount({
            debtor: debtor, originalCreditor: originalCreditor,
            originalBalance: balance, currentBalance: balance, accruedInterest: FHE.asEuint64(0),
            commissionRateBps: commission, purchasedAt: block.timestamp, lastActivity: block.timestamp,
            status: DebtStatus.Active, collector: msg.sender
        });
        _totalDebtPortfolio = FHE.add(_totalDebtPortfolio, balance);
        FHE.allowThis(accounts[id].originalBalance);
        FHE.allowThis(accounts[id].currentBalance);
        FHE.allow(accounts[id].currentBalance, debtor);
        FHE.allowThis(accounts[id].accruedInterest);
        FHE.allowThis(accounts[id].commissionRateBps);
        FHE.allowThis(_totalDebtPortfolio);
        if (!FHE.isInitialized(_collectorEarnings[msg.sender])) {
            _collectorEarnings[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_collectorEarnings[msg.sender]);
        }
        emit AccountPurchased(id, msg.sender);
    }

    function receivePayment(uint256 accountId, externalEuint64 encPayment, bytes calldata proof) external {
        DebtAccount storage acc = accounts[accountId];
        require(acc.collector == msg.sender || isCollector[msg.sender], "Not collector");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool fullPayment = FHE.ge(payment, acc.currentBalance);
        euint64 appliedPayment = FHE.select(fullPayment, acc.currentBalance, payment);
        acc.currentBalance = FHE.sub(acc.currentBalance, appliedPayment);
        _totalRecovered = FHE.add(_totalRecovered, appliedPayment);
        // Commission
        euint64 commission = FHE.div(FHE.mul(appliedPayment, acc.commissionRateBps), 10000);
        _collectorEarnings[acc.collector] = FHE.add(_collectorEarnings[acc.collector], commission);
        acc.lastActivity = block.timestamp;
        FHE.allowThis(acc.currentBalance);
        FHE.allow(acc.currentBalance, acc.debtor);
        FHE.allowThis(_totalRecovered);
        FHE.allowThis(_collectorEarnings[acc.collector]);
        FHE.allow(_collectorEarnings[acc.collector], acc.collector);
        if (FHE.isInitialized(fullPayment)) {
            acc.status = DebtStatus.FullSettlement;
            emit AccountSettled(accountId, DebtStatus.FullSettlement);
        }
        emit PaymentReceived(accountId);
    }

    function markDispute(uint256 accountId) external {
        require(accounts[accountId].debtor == msg.sender, "Not debtor");
        accounts[accountId].status = DebtStatus.InDispute;
    }

    function writeOff(uint256 accountId) external {
        require(isCollector[msg.sender], "Not collector");
        accounts[accountId].status = DebtStatus.WrittenOff;
        _totalDebtPortfolio = FHE.sub(_totalDebtPortfolio, accounts[accountId].currentBalance);
        FHE.allowThis(_totalDebtPortfolio);
        emit AccountSettled(accountId, DebtStatus.WrittenOff);
    }

    function allowAccountDetails(uint256 id, address viewer) external {
        DebtAccount storage acc = accounts[id];
        require(msg.sender == acc.collector || msg.sender == acc.debtor || msg.sender == owner(), "Unauthorized");
        FHE.allow(acc.originalBalance, viewer);
        FHE.allow(acc.currentBalance, viewer);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalDebtPortfolio, viewer);
        FHE.allow(_totalRecovered, viewer);
    }
}
