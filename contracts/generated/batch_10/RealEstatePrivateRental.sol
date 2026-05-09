// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RealEstatePrivateRental
/// @notice Rental property management with encrypted rental income, tenant
///         financial qualifications, and occupancy metrics. Landlords cannot
///         discriminate based on visible financial data.
contract RealEstatePrivateRental is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        string address_;
        euint64 monthlyRent;
        euint64 depositAmount;
        euint8 occupancyStatus; // 0=vacant, 1=occupied (encrypted)
        euint16 creditScoreRequired;
        uint256 leaseStart;
        uint256 leaseEnd;
        address currentTenant;
        bool listed;
    }

    struct TenantApplication {
        address applicant;
        uint256 propertyId;
        euint16 creditScore;     // encrypted
        euint64 monthlyIncome;   // encrypted
        euint8 previousEvictions; // encrypted: 0=none, 1+=has evictions
        bool approved;
        bool rejected;
        uint256 appliedAt;
    }

    struct RentPayment {
        euint64 amount;
        uint256 paidAt;
        bool onTime;
    }

    mapping(uint256 => Property) private properties;
    uint256 public propertyCount;
    mapping(uint256 => TenantApplication) private applications;
    uint256 public applicationCount;
    mapping(address => uint256[]) private tenantApplications;
    mapping(uint256 => RentPayment[]) private rentHistory;
    euint64 private _totalRentalIncome;

    event PropertyListed(uint256 indexed id, address landlord);
    event ApplicationSubmitted(uint256 indexed appId, uint256 propertyId);
    event TenantApproved(uint256 indexed propertyId, address tenant);
    event RentPaid(uint256 indexed propertyId, address tenant);

    constructor() Ownable(msg.sender) {
        _totalRentalIncome = FHE.asEuint64(0);
        FHE.allowThis(_totalRentalIncome);
    }

    function listProperty(
        string calldata addr, uint256 leaseDurationDays,
        externalEuint64 encRent, bytes calldata rProof,
        externalEuint64 encDeposit, bytes calldata dProof,
        externalEuint16 encMinCredit, bytes calldata cProof
    ) external returns (uint256 id) {
        id = propertyCount++;
        properties[id].address_ = addr;
        properties[id].monthlyRent = FHE.fromExternal(encRent, rProof);
        properties[id].depositAmount = FHE.fromExternal(encDeposit, dProof);
        properties[id].creditScoreRequired = FHE.fromExternal(encMinCredit, cProof);
        properties[id].occupancyStatus = FHE.asEuint8(0);
        properties[id].leaseEnd = block.timestamp + leaseDurationDays * 1 days;
        properties[id].listed = true;
        FHE.allowThis(properties[id].monthlyRent);
        FHE.allow(properties[id].monthlyRent, msg.sender);
        FHE.allowThis(properties[id].depositAmount);
        FHE.allow(properties[id].depositAmount, msg.sender);
        FHE.allowThis(properties[id].creditScoreRequired);
        FHE.allowThis(properties[id].occupancyStatus);
        emit PropertyListed(id, msg.sender);
    }

    function applyForRental(
        uint256 propertyId,
        externalEuint16 encCredit, bytes calldata cProof,
        externalEuint64 encIncome, bytes calldata iProof,
        externalEuint8 encEvictions, bytes calldata eProof
    ) external returns (uint256 id) {
        require(properties[propertyId].listed && properties[propertyId].currentTenant == address(0), "Not available");
        id = applicationCount++;
        applications[id] = TenantApplication({
            applicant: msg.sender,
            propertyId: propertyId,
            creditScore: FHE.fromExternal(encCredit, cProof),
            monthlyIncome: FHE.fromExternal(encIncome, iProof),
            previousEvictions: FHE.fromExternal(encEvictions, eProof),
            approved: false, rejected: false,
            appliedAt: block.timestamp
        });
        FHE.allowThis(applications[id].creditScore);
        FHE.allow(applications[id].creditScore, msg.sender);
        FHE.allowThis(applications[id].monthlyIncome);
        FHE.allow(applications[id].monthlyIncome, msg.sender);
        FHE.allowThis(applications[id].previousEvictions);
        tenantApplications[msg.sender].push(id);
        emit ApplicationSubmitted(id, propertyId);
    }

    function approveApplication(uint256 applicationId) external onlyOwner {
        TenantApplication storage app = applications[applicationId];
        require(!app.approved && !app.rejected, "Already decided");
        Property storage prop = properties[app.propertyId];
        // Check credit score threshold
        ebool creditOk = FHE.ge(app.creditScore, prop.creditScoreRequired);
        ebool noEvictions = FHE.eq(app.previousEvictions, FHE.asEuint8(0));
        ebool qualified = FHE.and(creditOk, noEvictions);
        app.approved = FHE.isInitialized(qualified);
        if (app.approved) {
            prop.currentTenant = app.applicant;
            prop.occupancyStatus = FHE.asEuint8(1);
            prop.leaseStart = block.timestamp;
            FHE.allowThis(prop.occupancyStatus);
            FHE.allow(prop.monthlyRent, app.applicant);
            FHE.allow(prop.depositAmount, app.applicant);
            emit TenantApproved(app.propertyId, app.applicant);
        } else {
            app.rejected = true;
        }
    }

    function payRent(uint256 propertyId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        Property storage prop = properties[propertyId];
        require(prop.currentTenant == msg.sender, "Not tenant");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        bool onTime = block.timestamp <= prop.leaseEnd;
        rentHistory[propertyId].push(RentPayment({ amount: amount, paidAt: block.timestamp, onTime: onTime }));
        uint256 idx = rentHistory[propertyId].length - 1;
        _totalRentalIncome = FHE.add(_totalRentalIncome, amount);
        FHE.allowThis(rentHistory[propertyId][idx].amount);
        FHE.allow(rentHistory[propertyId][idx].amount, msg.sender);
        FHE.allowThis(_totalRentalIncome);
        emit RentPaid(propertyId, msg.sender);
    }

    function allowPropertyData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(properties[id].monthlyRent, viewer);
        FHE.allow(properties[id].depositAmount, viewer);
        FHE.allow(properties[id].occupancyStatus, viewer);
    }
}
