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
        externalEuint64 calldata encValuation,
        bytes calldata valuationProof,
        externalEuint64 calldata encRental,
        bytes calldata rentalProof,
        externalEuint32 calldata encShares,
        bytes calldata sharesProof,
        externalEuint64 calldata encSharePrice,
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

    function purchaseShares(uint256 propId, externalEuint32 calldata encShares, bytes calldata inputProof)
        external
        nonReentrant
    {
        require(accreditedInvestors[msg.sender], "Not accredited");
        Property storage p = properties[propId];
        require(p.active, "Property inactive");
        euint32 shares = FHE.fromExternal(encShares, inputProof);
        euint64 cost = FHE.mul(FHE.asEuint64(shares.unwrap()), p.sharePrice);
        InvestorHolding storage h = holdings[propId][msg.sender];
        h.shares = FHE.add(h.shares, shares);
        h.totalInvested = FHE.add(h.totalInvested, cost);
        if (h.dividendsReceived.unwrap() == 0) h.dividendsReceived = FHE.asEuint64(0);
        FHE.allowThis(h.shares);
        FHE.allowThis(h.totalInvested);
        FHE.allowThis(h.dividendsReceived);
        FHE.allow(h.shares, msg.sender);
        FHE.allow(h.totalInvested, msg.sender);
        FHE.allow(h.dividendsReceived, msg.sender);
        emit SharesPurchased(propId, msg.sender);
    }

    function distributeDividend(uint256 propId, address investor) external onlyOwner nonReentrant {
        Property storage p = properties[propId];
        InvestorHolding storage h = holdings[propId][investor];
        euint64 dividend = FHE.div(
            FHE.mul(p.rentalIncome, FHE.asEuint64(h.shares.unwrap())),
            FHE.asEuint64(p.totalShares.unwrap())
        );
        h.dividendsReceived = FHE.add(h.dividendsReceived, dividend);
        FHE.allowThis(h.dividendsReceived);
        FHE.allow(h.dividendsReceived, investor);
        FHE.allowTransient(dividend, investor);
        emit DividendPaid(propId, investor);
    }

    function revalueProperty(uint256 propId, externalEuint64 calldata encNewVal, bytes calldata inputProof)
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
}
