// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSupplyChainFinanceInvoiceDiscount
/// @notice Encrypted supply chain finance invoice discounting: hidden invoice face values,
///         confidential early payment discount rates, private supplier credit scores,
///         and encrypted anchor buyer approval workflows.
contract PrivateSupplyChainFinanceInvoiceDiscount is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum InvoiceStatus { Submitted, BuyerApproved, Discounted, Settled, Defaulted }

    struct SCFInvoice {
        address supplier;
        address anchorBuyer;
        address financier;
        string invoiceRef;
        euint64 faceValueUSD;          // encrypted invoice face value
        euint64 discountRateBps;       // encrypted discount rate
        euint64 discountedValueUSD;    // encrypted proceeds to supplier
        euint64 financierReturnUSD;    // encrypted financier return at maturity
        euint16 supplierCreditScore;   // encrypted supplier credit score
        InvoiceStatus status;
        uint256 invoiceDate;
        uint256 paymentDueDate;
    }

    mapping(uint256 => SCFInvoice) private invoices;
    mapping(address => bool) public isAnchorBuyer;
    mapping(address => bool) public isSCFFinancier;

    uint256 public invoiceCount;
    euint64 private _totalFinancedUSD;
    euint64 private _totalFinancierReturnUSD;

    event InvoiceSubmitted(uint256 indexed id, string invoiceRef);
    event InvoiceBuyerApproved(uint256 indexed id);
    event InvoiceDiscounted(uint256 indexed id);
    event InvoiceSettled(uint256 indexed id);

    modifier onlySCFFinancier() {
        require(isSCFFinancier[msg.sender] || msg.sender == owner(), "Not SCF financier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFinancedUSD = FHE.asEuint64(0);
        _totalFinancierReturnUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFinancedUSD);
        FHE.allowThis(_totalFinancierReturnUSD);
        isAnchorBuyer[msg.sender] = true;
        isSCFFinancier[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAnchorBuyer(address ab) external onlyOwner { isAnchorBuyer[ab] = true; }
    function addFinancier(address f) external onlyOwner { isSCFFinancier[f] = true; }

    function submitInvoice(
        address anchorBuyer, string calldata invoiceRef,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint16 encCreditScore, bytes calldata csProof,
        uint256 dueDays
    ) external whenNotPaused returns (uint256 id) {
        require(isAnchorBuyer[anchorBuyer], "Not anchor buyer");
        euint64 faceValue = FHE.fromExternal(encFaceValue, fvProof);
        euint16 creditScore = FHE.fromExternal(encCreditScore, csProof);
        id = invoiceCount++;
        SCFInvoice storage _s0 = invoices[id];
        _s0.supplier = msg.sender;
        _s0.anchorBuyer = anchorBuyer;
        _s0.financier = address(0);
        _s0.invoiceRef = invoiceRef;
        _s0.faceValueUSD = faceValue;
        _s0.discountRateBps = FHE.asEuint64(0);
        _s0.discountedValueUSD = FHE.asEuint64(0);
        _s0.financierReturnUSD = FHE.asEuint64(0);
        _s0.supplierCreditScore = creditScore;
        _s0.status = InvoiceStatus.Submitted;
        _s0.invoiceDate = block.timestamp;
        _s0.paymentDueDate = block.timestamp + dueDays * 1 days;
        FHE.allowThis(invoices[id].faceValueUSD); FHE.allow(invoices[id].faceValueUSD, msg.sender); FHE.allow(invoices[id].faceValueUSD, anchorBuyer);
        FHE.allowThis(invoices[id].discountRateBps);
        FHE.allowThis(invoices[id].discountedValueUSD); FHE.allow(invoices[id].discountedValueUSD, msg.sender);
        FHE.allowThis(invoices[id].financierReturnUSD);
        FHE.allowThis(invoices[id].supplierCreditScore);
        emit InvoiceSubmitted(id, invoiceRef);
    }

    function buyerApproveInvoice(uint256 invoiceId) external {
        SCFInvoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.anchorBuyer && inv.status == InvoiceStatus.Submitted, "Not buyer or wrong status");
        inv.status = InvoiceStatus.BuyerApproved;
        emit InvoiceBuyerApproved(invoiceId);
    }

    function discountInvoice(
        uint256 invoiceId,
        externalEuint64 encDiscountRate, bytes calldata drProof
    ) external onlySCFFinancier nonReentrant {
        SCFInvoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.BuyerApproved, "Not buyer approved");
        euint64 discountRate = FHE.fromExternal(encDiscountRate, drProof);
        euint64 discountAmt = FHE.div(FHE.mul(inv.faceValueUSD, discountRate), 10000);
        euint64 discountedValue = FHE.sub(inv.faceValueUSD, discountAmt);
        inv.financier = msg.sender;
        inv.discountRateBps = discountRate;
        inv.discountedValueUSD = discountedValue;
        inv.financierReturnUSD = discountAmt;
        inv.status = InvoiceStatus.Discounted;
        _totalFinancedUSD = FHE.add(_totalFinancedUSD, discountedValue);
        _totalFinancierReturnUSD = FHE.add(_totalFinancierReturnUSD, discountAmt);
        FHE.allowThis(inv.discountRateBps); FHE.allow(inv.discountRateBps, inv.supplier);
        FHE.allowThis(inv.discountedValueUSD); FHE.allow(inv.discountedValueUSD, inv.supplier);
        FHE.allowThis(inv.financierReturnUSD); FHE.allow(inv.financierReturnUSD, msg.sender);
        FHE.allowThis(_totalFinancedUSD);
        FHE.allowThis(_totalFinancierReturnUSD);
        emit InvoiceDiscounted(invoiceId);
    }

    function settleInvoice(uint256 invoiceId) external nonReentrant {
        SCFInvoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.anchorBuyer && inv.status == InvoiceStatus.Discounted, "Not eligible");
        inv.status = InvoiceStatus.Settled;
        emit InvoiceSettled(invoiceId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalFinancedUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalFinancedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFinancierReturnUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFinancierReturnUSD, viewer);
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