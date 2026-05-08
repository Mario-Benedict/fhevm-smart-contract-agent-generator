// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialSupplyChainFinanceToken
/// @notice Encrypted supply chain finance token: hidden invoice face values,
///         private early-pay discount rates, confidential supplier credit scores,
///         and encrypted dynamic pricing based on supply chain risk metrics.
contract ConfidentialSupplyChainFinanceToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "SCF Token";
    string public constant symbol = "SCFT";
    uint8  public constant decimals = 6;

    struct Invoice {
        address supplier;
        address buyer;
        string invoiceRef;
        euint64 faceValueUSD;          // encrypted face value
        euint64 discountRateBps;       // encrypted early-pay discount rate
        euint64 earlyPayAmountUSD;     // encrypted discounted amount
        euint16 supplierCreditScore;   // encrypted supplier credit score
        euint16 supplyChainRiskScore;  // encrypted supply chain risk
        uint256 dueDate;
        bool financed;
        bool settled;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => Invoice) private invoices;
    mapping(address => bool) public isFinancier;

    uint256 public invoiceCount;
    euint64 private _totalSupply;
    euint64 private _totalInvoiceValueUSD;
    euint64 private _totalDiscountEarnedUSD;

    event Transfer(address indexed from, address indexed to);
    event InvoiceSubmitted(uint256 indexed id, address supplier, address buyer);
    event InvoiceFinanced(uint256 indexed id, uint256 financedAt);
    event InvoiceSettled(uint256 indexed id, uint256 settledAt);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalInvoiceValueUSD = FHE.asEuint64(0);
        _totalDiscountEarnedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalInvoiceValueUSD);
        FHE.allowThis(_totalDiscountEarnedUSD);
        isFinancier[msg.sender] = true;
    }

    function addFinancier(address f) external onlyOwner { isFinancier[f] = true; }

    function submitInvoice(
        address buyer, string calldata invoiceRef,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint64 encDiscountRate, bytes calldata drProof,
        externalEuint16 encCreditScore, bytes calldata csProof,
        externalEuint16 encRiskScore, bytes calldata rsProof,
        uint256 dueDays
    ) external returns (uint256 id) {
        euint64 faceValue    = FHE.fromExternal(encFaceValue, fvProof);
        euint64 discountRate = FHE.fromExternal(encDiscountRate, drProof);
        euint16 creditScore  = FHE.fromExternal(encCreditScore, csProof);
        euint16 riskScore    = FHE.fromExternal(encRiskScore, rsProof);
        euint64 discount     = FHE.div(FHE.mul(faceValue, discountRate), 10000);
        euint64 earlyPay     = FHE.sub(faceValue, discount);
        id = invoiceCount++;
        invoices[id] = Invoice({
            supplier: msg.sender, buyer: buyer, invoiceRef: invoiceRef, faceValueUSD: faceValue,
            discountRateBps: discountRate, earlyPayAmountUSD: earlyPay, supplierCreditScore: creditScore,
            supplyChainRiskScore: riskScore, dueDate: block.timestamp + dueDays * 1 days,
            financed: false, settled: false
        });
        _totalInvoiceValueUSD = FHE.add(_totalInvoiceValueUSD, faceValue);
        FHE.allowThis(invoices[id].faceValueUSD); FHE.allow(invoices[id].faceValueUSD, msg.sender); FHE.allow(invoices[id].faceValueUSD, buyer);
        FHE.allowThis(invoices[id].discountRateBps); FHE.allow(invoices[id].discountRateBps, msg.sender);
        FHE.allowThis(invoices[id].earlyPayAmountUSD); FHE.allow(invoices[id].earlyPayAmountUSD, msg.sender);
        FHE.allowThis(invoices[id].supplierCreditScore);
        FHE.allowThis(invoices[id].supplyChainRiskScore);
        FHE.allowThis(_totalInvoiceValueUSD);
        emit InvoiceSubmitted(id, msg.sender, buyer);
    }

    function financeInvoice(uint256 invoiceId) external nonReentrant {
        require(isFinancier[msg.sender], "Not financier");
        Invoice storage inv = invoices[invoiceId];
        require(!inv.financed, "Already financed");
        // Mint SCF tokens equal to early-pay amount to supplier
        if (!FHE.isInitialized(_balances[inv.supplier])) { _balances[inv.supplier] = FHE.asEuint64(0); FHE.allowThis(_balances[inv.supplier]); }
        _balances[inv.supplier] = FHE.add(_balances[inv.supplier], inv.earlyPayAmountUSD);
        _totalSupply = FHE.add(_totalSupply, inv.earlyPayAmountUSD);
        _totalDiscountEarnedUSD = FHE.add(_totalDiscountEarnedUSD, FHE.sub(inv.faceValueUSD, inv.earlyPayAmountUSD));
        inv.financed = true;
        FHE.allowThis(_balances[inv.supplier]); FHE.allow(_balances[inv.supplier], inv.supplier);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalDiscountEarnedUSD);
        emit InvoiceFinanced(invoiceId, block.timestamp);
    }

    function settleInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        require(msg.sender == inv.buyer && inv.financed && !inv.settled, "Cannot settle");
        inv.settled = true;
        emit InvoiceSettled(invoiceId, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], eff);
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function allowSCFStats(address viewer) external onlyOwner {
        FHE.allow(_totalInvoiceValueUSD, viewer); FHE.allow(_totalDiscountEarnedUSD, viewer);
    }
}
