// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateLuxuryRealEstateTokenization
/// @notice Luxury real estate fractional ownership where property valuations,
///         individual ownership percentages, rental income distributions,
///         and transaction prices remain encrypted to maintain seller privacy.
contract PrivateLuxuryRealEstateTokenization is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        euint64 appraisedValueUSD;   // encrypted current valuation
        euint64 rentalIncomeMonthly; // encrypted monthly rental
        euint64 totalFractions;      // total tokenized fractions
        euint32 occupancyRateBps;    // encrypted occupancy rate
        euint32 managementFeeBps;    // management company fee
        string locationCode;         // anonymized (city code, not address)
        bool active;
        bool forSale;
        uint256 lastAppraisalDate;
        uint256 listingDate;
    }

    struct FractionalHolder {
        euint64 fractionCount;
        euint64 accruedRental;
        uint256 acquisitionDate;
    }

    mapping(uint8 => Property) private properties;
    mapping(uint8 => mapping(address => FractionalHolder)) private holdings;
    mapping(uint8 => address[]) private propertyHolders;
    uint8 public propertyCount;

    euint64 private _totalPortfolioValue;
    euint64 private _totalRentalDistributed;

    event PropertyListed(uint8 indexed propertyId, string locationCode);
    event FractionsPurchased(uint8 indexed propertyId, address indexed buyer);
    event RentalDistributed(uint8 indexed propertyId);
    event PropertyRevalued(uint8 indexed propertyId);

    constructor() Ownable(msg.sender) {
        _totalPortfolioValue = FHE.asEuint64(0);
        _totalRentalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioValue);
        FHE.allowThis(_totalRentalDistributed);
    }

    function listProperty(
        externalEuint64 encValue, bytes calldata valProof,
        externalEuint64 encRental, bytes calldata rentProof,
        externalEuint64 encFractions, bytes calldata fracProof,
        externalEuint32 encOccupancy, bytes calldata occProof,
        externalEuint32 encMgmtFee, bytes calldata feeProof,
        string calldata locationCode
    ) external onlyOwner returns (uint8 propertyId) {
        propertyId = propertyCount++;
        Property storage p = properties[propertyId];
        p.appraisedValueUSD = FHE.fromExternal(encValue, valProof);
        p.rentalIncomeMonthly = FHE.fromExternal(encRental, rentProof);
        p.totalFractions = FHE.fromExternal(encFractions, fracProof);
        p.occupancyRateBps = FHE.fromExternal(encOccupancy, occProof);
        p.managementFeeBps = FHE.fromExternal(encMgmtFee, feeProof);
        p.locationCode = locationCode;
        p.active = true;
        p.forSale = true;
        p.listingDate = block.timestamp;
        p.lastAppraisalDate = block.timestamp;
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, p.appraisedValueUSD);
        FHE.allowThis(p.appraisedValueUSD);
        FHE.allowThis(p.rentalIncomeMonthly);
        FHE.allowThis(p.totalFractions);
        FHE.allowThis(p.occupancyRateBps);
        FHE.allowThis(p.managementFeeBps);
        FHE.allowThis(_totalPortfolioValue);
        emit PropertyListed(propertyId, locationCode);
    }

    function purchaseFractions(
        uint8 propertyId,
        externalEuint64 encFractions, bytes calldata proof
    ) external nonReentrant {
        require(propertyId < propertyCount && properties[propertyId].active, "Not available");
        euint64 fractions = FHE.fromExternal(encFractions, proof);
        FractionalHolder storage h = holdings[propertyId][msg.sender];
        if (h.fractionCount.eq(FHE.asEuint64(0)) == FHE.eq(FHE.asEuint64(0), FHE.asEuint64(0))) {
            h.fractionCount = FHE.asEuint64(0);
            h.accruedRental = FHE.asEuint64(0);
            FHE.allowThis(h.fractionCount);
            FHE.allowThis(h.accruedRental);
            h.acquisitionDate = block.timestamp;
            propertyHolders[propertyId].push(msg.sender);
        }
        h.fractionCount = FHE.add(h.fractionCount, fractions);
        FHE.allowThis(h.fractionCount);
        FHE.allow(h.fractionCount, msg.sender);
        emit FractionsPurchased(propertyId, msg.sender);
    }

    function distributeRental(uint8 propertyId, address holder) external onlyOwner nonReentrant {
        require(propertyId < propertyCount && properties[propertyId].active, "Not available");
        FractionalHolder storage h = holdings[propertyId][holder];
        Property storage p = properties[propertyId];
        // Rental share = fractions / totalFractions * monthly * (1 - mgmtFee/10000)
        euint64 grossShare = FHE.div(
            FHE.mul(h.fractionCount, p.rentalIncomeMonthly),
            p.totalFractions
        );
        euint64 mgmtFee = FHE.div(FHE.mul(grossShare, FHE.asEuint64(uint64(0))), 10000);
        mgmtFee = FHE.div(grossShare, 20); // 5% simplified
        euint64 netShare = FHE.sub(grossShare, mgmtFee);
        h.accruedRental = FHE.add(h.accruedRental, netShare);
        _totalRentalDistributed = FHE.add(_totalRentalDistributed, netShare);
        FHE.allowThis(h.accruedRental);
        FHE.allow(h.accruedRental, holder);
        FHE.allow(netShare, holder);
        FHE.allowThis(_totalRentalDistributed);
        emit RentalDistributed(propertyId);
    }

    function claimRental(uint8 propertyId) external nonReentrant {
        FractionalHolder storage h = holdings[propertyId][msg.sender];
        euint64 amount = h.accruedRental;
        h.accruedRental = FHE.asEuint64(0);
        FHE.allowThis(h.accruedRental);
        FHE.allow(amount, msg.sender);
    }

    function revalueProperty(
        uint8 propertyId,
        externalEuint64 encNewValue, bytes calldata proof
    ) external onlyOwner {
        require(propertyId < propertyCount, "Invalid property");
        euint64 oldValue = properties[propertyId].appraisedValueUSD;
        properties[propertyId].appraisedValueUSD = FHE.fromExternal(encNewValue, proof);
        _totalPortfolioValue = FHE.sub(_totalPortfolioValue, oldValue);
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, properties[propertyId].appraisedValueUSD);
        properties[propertyId].lastAppraisalDate = block.timestamp;
        FHE.allowThis(properties[propertyId].appraisedValueUSD);
        FHE.allowThis(_totalPortfolioValue);
        emit PropertyRevalued(propertyId);
    }

    function allowMyHoldings(uint8 propertyId, address viewer) external {
        FHE.allow(holdings[propertyId][msg.sender].fractionCount, viewer);
        FHE.allow(holdings[propertyId][msg.sender].accruedRental, viewer);
    }

    function allowPortfolioMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalPortfolioValue, viewer);
        FHE.allow(_totalRentalDistributed, viewer);
    }
}
