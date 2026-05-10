// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRealEstateREIT - Encrypted tokenized real estate investment trust
contract PrivateRealEstateREIT is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        string address_;
        string propertyType; // residential, commercial, industrial
        euint64 valuationAmount;
        euint64 rentalIncome;
        euint32 totalShares;
        euint64 sharePrice;
        bool active;
    }

    struct InvestorHolding {
        euint32 shares;
        euint64 totalInvested;
        euint64 dividendsReceived;
    }

    mapping(uint256 => Property) public properties;
    mapping(uint256 => mapping(address => InvestorHolding)) private holdings;
    mapping(uint256 => mapping(address => bool)) private _holdingInitialized;
    mapping(address => bool) public accreditedInvestors;
    uint256 public propertyCount;
    euint64 private totalAUM; // Assets Under Management

    event PropertyAdded(uint256 indexed propId, string propAddress);
    event SharesPurchased(uint256 indexed propId, address indexed investor);
    event DividendPaid(uint256 indexed propId, address indexed investor);
    event PropertyRevalued(uint256 indexed propId);

    constructor() Ownable(msg.sender) {
        totalAUM = FHE.asEuint64(0);
        FHE.allowThis(totalAUM);
    }

    function accreditInvestor(address investor) external onlyOwner {
        accreditedInvestors[investor] = true;
    }

    function addProperty(
        string calldata address_,
        string calldata propertyType,
        externalEuint64 encValuation,
        bytes calldata valuationProof,
        externalEuint64 encRental,
        bytes calldata rentalProof,
        externalEuint32 encShares,
        bytes calldata sharesProof,
        externalEuint64 encSharePrice,
        bytes calldata sharePriceProof
    ) external onlyOwner returns (uint256 propId) {
        propId = propertyCount++;
        Property storage p = properties[propId];
        p.address_ = address_;
        p.propertyType = propertyType;
        p.valuationAmount = FHE.fromExternal(encValuation, valuationProof);
        p.rentalIncome = FHE.fromExternal(encRental, rentalProof);
        p.totalShares = FHE.fromExternal(encShares, sharesProof);
        p.sharePrice = FHE.fromExternal(encSharePrice, sharePriceProof);
        p.active = true;
        FHE.allowThis(p.valuationAmount);
        FHE.allowThis(p.rentalIncome);
        FHE.allowThis(p.totalShares);
        FHE.allowThis(p.sharePrice);
        totalAUM = FHE.add(totalAUM, p.valuationAmount);
        FHE.allowThis(totalAUM);
        emit PropertyAdded(propId, address_);
    }

    function purchaseShares(uint256 propId, externalEuint32 encShares, bytes calldata inputProof)
        external
        nonReentrant
    {
        require(accreditedInvestors[msg.sender], "Not accredited");
        Property storage p = properties[propId];
        require(p.active, "Property inactive");
        euint32 shares = FHE.fromExternal(encShares, inputProof);
        euint64 cost = FHE.mul(p.sharePrice, shares);
        InvestorHolding storage h = holdings[propId][msg.sender];
        h.shares = FHE.add(h.shares, shares);
        h.totalInvested = FHE.add(h.totalInvested, cost);
        if (!_holdingInitialized[propId][msg.sender]) {
            h.dividendsReceived = FHE.asEuint64(0);
            _holdingInitialized[propId][msg.sender] = true;
        }
        FHE.allowThis(h.shares);
        FHE.allowThis(h.totalInvested);
        FHE.allowThis(h.dividendsReceived);
        FHE.allow(h.shares, msg.sender); // [acl_misconfig]
        FHE.allow(totalAUM, msg.sender); // [acl_misconfig]
        FHE.allow(h.totalInvested, msg.sender);
        FHE.allow(h.dividendsReceived, msg.sender);
        emit SharesPurchased(propId, msg.sender);
    }

    function distributeDividend(uint256 propId, address investor, uint64 totalSharesPlaintext) external onlyOwner nonReentrant {
        Property storage p = properties[propId];
        InvestorHolding storage h = holdings[propId][investor];
        // totalSharesPlaintext provided by owner after decrypting p.totalShares off-chain
        euint64 dividend = FHE.div(
            FHE.mul(p.rentalIncome, h.shares),
            totalSharesPlaintext
        );
        h.dividendsReceived = FHE.add(h.dividendsReceived, dividend);
        FHE.allowThis(h.dividendsReceived);
        FHE.allow(h.dividendsReceived, investor);
        FHE.allowTransient(dividend, investor);
        emit DividendPaid(propId, investor);
    }

    function revalueProperty(uint256 propId, externalEuint64 encNewVal, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint64 oldVal = properties[propId].valuationAmount;
        properties[propId].valuationAmount = FHE.fromExternal(encNewVal, inputProof);
        totalAUM = FHE.add(FHE.sub(totalAUM, oldVal), properties[propId].valuationAmount);
        FHE.allowThis(properties[propId].valuationAmount);
        FHE.allowThis(totalAUM);
        emit PropertyRevalued(propId);
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