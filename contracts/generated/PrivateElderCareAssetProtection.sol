// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateElderCareAssetProtection
/// @notice Confidential elder care financial management: encrypted asset declarations,
///         hidden healthcare cost reserves, private Medicaid spend-down thresholds,
///         and encrypted family financial disclosure for care planning.
contract PrivateElderCareAssetProtection is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CareLevel { Independent, AssistedLiving, MemoryCare, NursingFacility, PalliativeCare }
    enum AssetType { RealEstate, InvestmentAccount, LifeInsurance, Pension, BusinessInterest, PersonalProperty }

    struct ElderProfile {
        address elder;
        address primaryCaregiver;
        CareLevel careLevel;
        euint64 totalAssetValueUSD;    // encrypted total assets
        euint64 medicaidThresholdUSD;  // encrypted Medicaid eligibility threshold
        euint64 monthlyCareCostUSD;    // encrypted monthly care cost
        euint64 careReserveUSD;        // encrypted care reserve fund
        euint32 estimatedCareMonths;   // encrypted care duration estimate
        bool active;
        uint256 enrolledAt;
    }

    struct ProtectedAsset {
        uint256 elderId;
        AssetType assetType;
        string description;
        euint64 currentValueUSD;       // encrypted asset value
        euint64 protectedAmountUSD;    // encrypted protected portion
        bool medicaidExempt;
        uint256 lastValuationAt;
    }

    struct CarePayment {
        uint256 elderId;
        euint64 amountUSD;             // encrypted payment amount
        string paymentPurpose;
        uint256 paidAt;
    }

    mapping(uint256 => ElderProfile) private profiles;
    mapping(uint256 => ProtectedAsset) private protectedAssets;
    mapping(uint256 => CarePayment) private carePayments;
    mapping(address => bool) public isCareCoordinator;
    mapping(address => bool) public isMedicaidOfficer;

    uint256 public profileCount;
    uint256 public assetCount;
    uint256 public paymentCount;
    euint64 private _totalAssetsUnderManagementUSD;
    euint64 private _totalCarePaymentsUSD;

    event ElderEnrolled(uint256 indexed id, CareLevel careLevel);
    event AssetRecorded(uint256 indexed assetId, uint256 elderId, AssetType assetType);
    event CarePaymentMade(uint256 indexed paymentId, uint256 elderId);
    event CareLevelUpdated(uint256 indexed elderId, CareLevel newLevel);

    modifier onlyCareCoordinator() {
        require(isCareCoordinator[msg.sender] || msg.sender == owner(), "Not care coordinator");
        _;
    }

    modifier onlyMedicaidOfficer() {
        require(isMedicaidOfficer[msg.sender] || msg.sender == owner(), "Not Medicaid officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAssetsUnderManagementUSD = FHE.asEuint64(0);
        _totalCarePaymentsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAssetsUnderManagementUSD);
        FHE.allowThis(_totalCarePaymentsUSD);
        isCareCoordinator[msg.sender] = true;
        isMedicaidOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addCareCoordinator(address c) external onlyOwner { isCareCoordinator[c] = true; }
    function addMedicaidOfficer(address m) external onlyOwner { isMedicaidOfficer[m] = true; }

    function enrollElder(
        address elder,
        address primaryCaregiver,
        CareLevel careLevel,
        externalEuint64 encTotalAssets, bytes calldata taProof,
        externalEuint64 encMedicaidThreshold, bytes calldata mtProof,
        externalEuint64 encMonthlyCost, bytes calldata mcProof,
        externalEuint32 encCareMonths, bytes calldata cmProof
    ) external onlyCareCoordinator whenNotPaused returns (uint256 id) {
        euint64 totalAssets = FHE.fromExternal(encTotalAssets, taProof);
        euint64 medThreshold = FHE.fromExternal(encMedicaidThreshold, mtProof);
        euint64 monthlyCost = FHE.fromExternal(encMonthlyCost, mcProof);
        euint32 careMonths = FHE.fromExternal(encCareMonths, cmProof);
        id = profileCount++;
        profiles[id] = ElderProfile({
            elder: elder, primaryCaregiver: primaryCaregiver, careLevel: careLevel,
            totalAssetValueUSD: totalAssets, medicaidThresholdUSD: medThreshold,
            monthlyCareCostUSD: monthlyCost, careReserveUSD: FHE.asEuint64(0),
            estimatedCareMonths: careMonths, active: true, enrolledAt: block.timestamp
        });
        _totalAssetsUnderManagementUSD = FHE.add(_totalAssetsUnderManagementUSD, totalAssets);
        FHE.allowThis(profiles[id].totalAssetValueUSD); FHE.allow(profiles[id].totalAssetValueUSD, elder); FHE.allow(profiles[id].totalAssetValueUSD, primaryCaregiver);
        FHE.allowThis(profiles[id].medicaidThresholdUSD);
        FHE.allowThis(profiles[id].monthlyCareCostUSD); FHE.allow(profiles[id].monthlyCareCostUSD, elder);
        FHE.allowThis(profiles[id].careReserveUSD); FHE.allow(profiles[id].careReserveUSD, primaryCaregiver);
        FHE.allowThis(profiles[id].estimatedCareMonths); FHE.allow(profiles[id].estimatedCareMonths, primaryCaregiver);
        FHE.allowThis(_totalAssetsUnderManagementUSD);
        emit ElderEnrolled(id, careLevel);
    }

    function recordProtectedAsset(
        uint256 elderId,
        AssetType assetType,
        string calldata description,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encProtected, bytes calldata pProof,
        bool medicaidExempt
    ) external onlyMedicaidOfficer whenNotPaused returns (uint256 assetId) {
        euint64 assetValue = FHE.fromExternal(encValue, vProof);
        euint64 protectedAmt = FHE.fromExternal(encProtected, pProof);
        assetId = assetCount++;
        protectedAssets[assetId] = ProtectedAsset({
            elderId: elderId, assetType: assetType, description: description,
            currentValueUSD: assetValue, protectedAmountUSD: protectedAmt,
            medicaidExempt: medicaidExempt, lastValuationAt: block.timestamp
        });
        ElderProfile storage ep = profiles[elderId];
        FHE.allowThis(protectedAssets[assetId].currentValueUSD); FHE.allow(protectedAssets[assetId].currentValueUSD, ep.elder); FHE.allow(protectedAssets[assetId].currentValueUSD, ep.primaryCaregiver);
        FHE.allowThis(protectedAssets[assetId].protectedAmountUSD); FHE.allow(protectedAssets[assetId].protectedAmountUSD, ep.primaryCaregiver);
        emit AssetRecorded(assetId, elderId, assetType);
    }

    function makeCarePayment(
        uint256 elderId,
        string calldata purpose,
        externalEuint64 encAmount, bytes calldata proof
    ) external onlyCareCoordinator nonReentrant returns (uint256 paymentId) {
        ElderProfile storage ep = profiles[elderId];
        require(ep.active, "Elder not active");
        euint64 amt = FHE.fromExternal(encAmount, proof);
        paymentId = paymentCount++;
        carePayments[paymentId] = CarePayment({
            elderId: elderId, amountUSD: amt, paymentPurpose: purpose, paidAt: block.timestamp
        });
        ep.careReserveUSD = FHE.sub(ep.careReserveUSD, amt);
        _totalCarePaymentsUSD = FHE.add(_totalCarePaymentsUSD, amt);
        FHE.allowThis(carePayments[paymentId].amountUSD); FHE.allow(carePayments[paymentId].amountUSD, ep.elder); FHE.allow(carePayments[paymentId].amountUSD, ep.primaryCaregiver);
        FHE.allowThis(ep.careReserveUSD); FHE.allow(ep.careReserveUSD, ep.primaryCaregiver);
        FHE.allowThis(_totalCarePaymentsUSD);
        emit CarePaymentMade(paymentId, elderId);
    }

    function fundCareReserve(
        uint256 elderId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        ElderProfile storage ep = profiles[elderId];
        require(msg.sender == ep.primaryCaregiver || msg.sender == ep.elder || msg.sender == owner(), "Not authorized");
        euint64 amt = FHE.fromExternal(encAmount, proof);
        ep.careReserveUSD = FHE.add(ep.careReserveUSD, amt);
        FHE.allowThis(ep.careReserveUSD); FHE.allow(ep.careReserveUSD, ep.elder); FHE.allow(ep.careReserveUSD, ep.primaryCaregiver);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalAssetsUnderManagementUSD, viewer);
        FHE.allow(_totalCarePaymentsUSD, viewer);
    }
}
