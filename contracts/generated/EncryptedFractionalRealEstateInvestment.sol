// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedFractionalRealEstateInvestment
/// @notice Fractional property investment platform where individual investor share
///         sizes, rental income distributions, and property valuations are encrypted.
///         Enables syndicated real estate deals with full privacy.
contract EncryptedFractionalRealEstateInvestment is ZamaEthereumConfig, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant APPRAISER_ROLE = keccak256("APPRAISER_ROLE");
    bytes32 public constant INVESTOR_ROLE = keccak256("INVESTOR_ROLE");

    struct Property {
        string propertyId;          // off-chain property reference
        string location;
        address manager;
        euint64 totalValuation;     // encrypted valuation
        euint32 totalShares;        // encrypted total share units
        euint64 rentalIncomePool;   // encrypted accumulated rental income
        bool active;
        uint256 listingDate;
    }

    struct InvestorPosition {
        euint32 shares;             // encrypted share count
        euint64 claimedIncome;      // encrypted amount already claimed
        euint64 pendingIncome;      // encrypted unclaimed income
        uint256 investmentDate;
    }

    uint256 public nextPropertyId;
    mapping(uint256 => Property) private properties;
    mapping(uint256 => mapping(address => InvestorPosition)) private positions;
    mapping(uint256 => address[]) private propertyInvestors;
    mapping(uint256 => euint64) private incomePerShare;  // encrypted income per share unit

    event PropertyListed(uint256 indexed propId, string location, address manager);
    event SharesSubscribed(uint256 indexed propId, address investor);
    event RentalIncomeDeposited(uint256 indexed propId);
    event IncomeDistributed(uint256 indexed propId, address investor);
    event ValuationUpdated(uint256 indexed propId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(APPRAISER_ROLE, msg.sender);
    }

    function listProperty(
        string calldata propertyId,
        string calldata location,
        externalEuint64 encValuation,
        bytes calldata valProof,
        externalEuint32 encTotalShares,
        bytes calldata sharesProof
    ) external onlyRole(MANAGER_ROLE) returns (uint256 propId) {
        propId = nextPropertyId++;
        properties[propId] = Property({
            propertyId: propertyId,
            location: location,
            manager: msg.sender,
            totalValuation: FHE.fromExternal(encValuation, valProof),
            totalShares: FHE.fromExternal(encTotalShares, sharesProof),
            rentalIncomePool: FHE.asEuint64(0),
            active: true,
            listingDate: block.timestamp
        });

        FHE.allowThis(properties[propId].totalValuation);
        FHE.allow(properties[propId].totalValuation, msg.sender);
        FHE.allowThis(properties[propId].totalShares);
        FHE.allowThis(properties[propId].rentalIncomePool);
        incomePerShare[propId] = FHE.asEuint64(0);
        FHE.allowThis(incomePerShare[propId]);

        emit PropertyListed(propId, location, msg.sender);
    }

    function subscribeShares(
        uint256 propId,
        externalEuint32 encShares,
        bytes calldata proof
    ) external onlyRole(INVESTOR_ROLE) whenNotPaused nonReentrant {
        Property storage p = properties[propId];
        require(p.active, "Not active");
        euint32 shares = FHE.fromExternal(encShares, proof);

        InvestorPosition storage pos = positions[propId][msg.sender];
        if (pos.investmentDate == 0) {
            pos.claimedIncome = FHE.asEuint64(0);
            pos.pendingIncome = FHE.asEuint64(0);
            pos.investmentDate = block.timestamp;
            propertyInvestors[propId].push(msg.sender);
        }
        pos.shares = FHE.add(pos.shares, shares);
        FHE.allowThis(pos.shares);
        FHE.allow(pos.shares, msg.sender);
        FHE.allowThis(pos.claimedIncome);
        FHE.allowThis(pos.pendingIncome);
        emit SharesSubscribed(propId, msg.sender);
    }

    function depositRentalIncome(
        uint256 propId,
        externalEuint64 encIncome,
        bytes calldata proof
    ) external onlyRole(MANAGER_ROLE) {
        Property storage p = properties[propId];
        require(p.active, "Not active");
        require(p.manager == msg.sender, "Not manager");
        euint64 income = FHE.fromExternal(encIncome, proof);
        p.rentalIncomePool = FHE.add(p.rentalIncomePool, income);
        FHE.allowThis(p.rentalIncomePool);
        // Update income per share (encrypted division)
        incomePerShare[propId] = FHE.add(incomePerShare[propId], FHE.div(income, uint64(p.totalShares)));
        FHE.allowThis(incomePerShare[propId]);
        emit RentalIncomeDeposited(propId);
    }

    function claimIncome(uint256 propId) external nonReentrant {
        InvestorPosition storage pos = positions[propId][msg.sender];
        require(pos.investmentDate > 0, "Not investor");
        euint64 earned = FHE.mul(incomePerShare[propId], FHE.asEuint64(uint64(pos.shares)));
        euint64 unclaimed = FHE.sub(earned, pos.claimedIncome);
        pos.claimedIncome = earned;
        pos.pendingIncome = FHE.add(pos.pendingIncome, unclaimed);
        FHE.allowThis(pos.claimedIncome);
        FHE.allowThis(pos.pendingIncome);
        FHE.allow(pos.pendingIncome, msg.sender);
        emit IncomeDistributed(propId, msg.sender);
    }

    function updateValuation(
        uint256 propId,
        externalEuint64 encVal,
        bytes calldata proof
    ) external onlyRole(APPRAISER_ROLE) {
        properties[propId].totalValuation = FHE.fromExternal(encVal, proof);
        FHE.allowThis(properties[propId].totalValuation);
        FHE.allow(properties[propId].totalValuation, properties[propId].manager);
        emit ValuationUpdated(propId);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
