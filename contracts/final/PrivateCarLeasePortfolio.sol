// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCarLeasePortfolio - Confidential auto lease origination with encrypted monthly payments and residuals
contract PrivateCarLeasePortfolio is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LeaseContract {
        address lessee;
        string  vehicleVIN;
        euint64 vehicleValue;
        euint64 residualValue;
        euint64 monthlyPayment;
        euint64 totalPaid;
        euint16 termMonths;
        euint16 monthsPaid;
        euint8  creditTier;      // 1=super prime … 5=subprime
        uint256 startDate;
        bool    defaulted;
        bool    active;
    }

    struct LeasePayment {
        uint256 paidAt;
        euint64 amount;
        bool    onTime;
    }

    mapping(uint256 => LeaseContract)   public leases;
    mapping(uint256 => LeasePayment[])  private paymentHistory;
    mapping(address => uint256[])       public lesseeLeases;
    mapping(address => bool)            public approvedDealers;
    euint64 private portfolioBalance;
    uint256 public leaseCount;

    event LeaseOriginated(uint256 indexed leaseId, address indexed lessee, string vin);
    event PaymentReceived(uint256 indexed leaseId, uint256 paymentIdx);
    event LeaseDefaulted(uint256 indexed leaseId);
    event LeaseMatured(uint256 indexed leaseId);

    constructor() Ownable(msg.sender) {
        portfolioBalance = FHE.asEuint64(0);
        FHE.allowThis(portfolioBalance);
    }

    function approveDealer(address dealer) external onlyOwner { approvedDealers[dealer] = true; }

    function originateLease(
        address lessee,
        string  calldata vehicleVIN,
        uint16  termMonths,
        externalEuint64 encVehicleVal, bytes calldata vehicleValProof,
        externalEuint64 encResidual,   bytes calldata residualProof,
        externalEuint64 encMonthly,    bytes calldata monthlyProof,
        externalEuint8 encCreditTier, bytes calldata creditTierProof
    ) external returns (uint256 leaseId) {
        require(approvedDealers[msg.sender], "Not approved dealer");
        leaseId = leaseCount++;
        LeaseContract storage l = leases[leaseId];
        l.lessee        = lessee;
        l.vehicleVIN    = vehicleVIN;
        l.vehicleValue  = FHE.fromExternal(encVehicleVal, vehicleValProof);
        l.residualValue = FHE.fromExternal(encResidual,   residualProof);
        l.monthlyPayment = FHE.fromExternal(encMonthly,   monthlyProof);
        l.creditTier    = FHE.fromExternal(encCreditTier, creditTierProof);
        l.totalPaid     = FHE.asEuint64(0);
        l.termMonths    = FHE.asEuint16(termMonths);
        l.monthsPaid    = FHE.asEuint16(0);
        l.startDate     = block.timestamp;
        l.active        = true;
        FHE.allowThis(l.vehicleValue); FHE.allowThis(l.residualValue);
        FHE.allowThis(l.monthlyPayment); FHE.allowThis(l.totalPaid);
        FHE.allowThis(l.termMonths); FHE.allowThis(l.monthsPaid); FHE.allowThis(l.creditTier);
        FHE.allow(l.monthlyPayment, lessee); FHE.allow(l.totalPaid, lessee);
        portfolioBalance = FHE.add(portfolioBalance, l.vehicleValue);
        FHE.allowThis(portfolioBalance);
        lesseeLeases[lessee].push(leaseId);
        emit LeaseOriginated(leaseId, lessee, vehicleVIN);
    }

    function recordPayment(
        uint256 leaseId, bool onTime,
        externalEuint64 encAmount, bytes calldata inputProof
    ) external onlyOwner nonReentrant {
        LeaseContract storage l = leases[leaseId];
        require(l.active && !l.defaulted, "Lease inactive");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        paymentHistory[leaseId].push(LeasePayment({ paidAt: block.timestamp, amount: amount, onTime: onTime }));
        uint256 idx = paymentHistory[leaseId].length - 1;
        l.totalPaid  = FHE.add(l.totalPaid, amount);
        l.monthsPaid = FHE.add(l.monthsPaid, FHE.asEuint16(1));
        FHE.allowThis(paymentHistory[leaseId][idx].amount);
        FHE.allowThis(l.totalPaid); FHE.allowThis(l.monthsPaid);
        FHE.allow(paymentHistory[leaseId][idx].amount, l.lessee);
        FHE.allow(l.totalPaid, l.lessee);
        ebool matured = FHE.ge(l.monthsPaid, l.termMonths);
        FHE.allowThis(matured);
        FHE.allow(matured, l.lessee);
        FHE.allow(matured, owner());
        emit PaymentReceived(leaseId, idx);
    }

    function markDefault(uint256 leaseId) external onlyOwner {
        leases[leaseId].defaulted = true;
        leases[leaseId].active    = false;
        emit LeaseDefaulted(leaseId);
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