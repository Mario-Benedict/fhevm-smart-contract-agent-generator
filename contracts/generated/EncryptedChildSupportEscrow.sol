// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedChildSupportEscrow
/// @notice Family court-ordered child support where payment amounts, schedules,
///         and compliance records are encrypted. Court officers can verify
///         compliance without exposing exact financials to third parties.
contract EncryptedChildSupportEscrow is ZamaEthereumConfig, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant COURT_ROLE = keccak256("COURT_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    enum OrderStatus { Active, Suspended, Completed, Disputed }

    struct SupportOrder {
        address payer;
        address payee;
        euint64 monthlyAmount;      // encrypted monthly obligation
        euint64 totalPaid;          // encrypted cumulative payments
        euint64 arrears;            // encrypted unpaid arrears
        uint256 orderDate;
        uint256 durationMonths;
        uint256 monthsPaid;
        OrderStatus status;
    }

    uint256 public nextOrderId;
    mapping(uint256 => SupportOrder) private orders;
    mapping(address => uint256[]) private payerOrders;
    mapping(address => uint256[]) private payeeOrders;

    event OrderCreated(uint256 indexed orderId, address payer, address payee);
    event PaymentMade(uint256 indexed orderId, uint256 month);
    event ArrearsUpdated(uint256 indexed orderId);
    event OrderDisputed(uint256 indexed orderId);
    event OrderCompleted(uint256 indexed orderId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COURT_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
    }

    function createOrder(
        address payer,
        address payee,
        externalEuint64 encMonthly,
        bytes calldata proof,
        uint256 durationMonths
    ) external onlyRole(COURT_ROLE) returns (uint256 orderId) {
        orderId = nextOrderId++;
        euint64 monthly = FHE.fromExternal(encMonthly, proof);

        orders[orderId] = SupportOrder({
            payer: payer,
            payee: payee,
            monthlyAmount: monthly,
            totalPaid: FHE.asEuint64(0),
            arrears: FHE.asEuint64(0),
            orderDate: block.timestamp,
            durationMonths: durationMonths,
            monthsPaid: 0,
            status: OrderStatus.Active
        });

        FHE.allowThis(orders[orderId].monthlyAmount);
        FHE.allow(orders[orderId].monthlyAmount, payer);
        FHE.allow(orders[orderId].monthlyAmount, payee);
        FHE.allowThis(orders[orderId].totalPaid);
        FHE.allowThis(orders[orderId].arrears);

        payerOrders[payer].push(orderId);
        payeeOrders[payee].push(orderId);
        emit OrderCreated(orderId, payer, payee);
    }

    function makePayment(
        uint256 orderId,
        externalEuint64 encPayment,
        bytes calldata proof
    ) external nonReentrant whenNotPaused {
        SupportOrder storage o = orders[orderId];
        require(msg.sender == o.payer, "Not payer");
        require(o.status == OrderStatus.Active, "Not active");

        euint64 payment = FHE.fromExternal(encPayment, proof);
        o.totalPaid = FHE.add(o.totalPaid, payment);
        FHE.allowThis(o.totalPaid);
        FHE.allow(o.totalPaid, o.payee);
        FHE.allow(o.totalPaid, o.payer);

        // Check if payment covers monthly obligation; if not, add deficit to arrears
        ebool coversFull = FHE.ge(payment, o.monthlyAmount);
        euint64 deficit = FHE.select(coversFull, FHE.asEuint64(0), FHE.sub(o.monthlyAmount, payment));
        o.arrears = FHE.add(o.arrears, deficit);
        FHE.allowThis(o.arrears);

        o.monthsPaid++;
        if (o.monthsPaid >= o.durationMonths) {
            o.status = OrderStatus.Completed;
            emit OrderCompleted(orderId);
        }
        emit PaymentMade(orderId, o.monthsPaid);
    }

    function recordArrears(uint256 orderId) external onlyRole(COURT_ROLE) {
        SupportOrder storage o = orders[orderId];
        require(o.status == OrderStatus.Active, "Not active");
        o.arrears = FHE.add(o.arrears, o.monthlyAmount);
        FHE.allowThis(o.arrears);
        emit ArrearsUpdated(orderId);
    }

    function disputeOrder(uint256 orderId) external onlyRole(COURT_ROLE) {
        orders[orderId].status = OrderStatus.Disputed;
        emit OrderDisputed(orderId);
    }

    function allowAudit(uint256 orderId, address auditor) external onlyRole(AUDITOR_ROLE) {
        FHE.allow(orders[orderId].totalPaid, auditor);
        FHE.allow(orders[orderId].arrears, auditor);
        FHE.allow(orders[orderId].monthlyAmount, auditor);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
