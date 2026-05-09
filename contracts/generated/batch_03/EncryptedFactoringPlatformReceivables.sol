// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFactoringPlatformReceivables
/// @notice Accounts receivable factoring with encrypted invoice face values,
///         advance rates, discount fees, and debtor creditworthiness scores.
///         Supports recourse and non-recourse factoring with reserve releases.
contract EncryptedFactoringPlatformReceivables is ZamaEthereumConfig, AccessControl, ReentrancyGuard {

    bytes32 public constant FACTOR_ROLE = keccak256("FACTOR_ROLE");
    bytes32 public constant ORIGINATOR_ROLE = keccak256("ORIGINATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    enum InvoiceStatus { SUBMITTED, VERIFIED, FUNDED, COLLECTED, DEFAULTED, DISPUTED }
    enum FactoringType { RECOURSE, NON_RECOURSE, SELECTIVE, WHOLE_TURNOVER }

    struct Invoice {
        address originator;
        address debtor;
        FactoringType factoringType;
        InvoiceStatus status;
        euint64 faceValue;          // encrypted invoice face value
        euint64 advanceAmount;      // encrypted amount advanced to originator
        euint64 reserveAmount;      // encrypted holdback reserve
        euint64 discountFee;        // encrypted factoring fee
        euint64 debtorCreditScore;  // encrypted debtor credit score (0-1000)
        euint64 advanceRateBps;     // encrypted advance rate in basis points
        uint256 invoiceDate;
        uint256 dueDate;
        uint256 fundedAt;
        bool verified;
    }

    struct OriginatorProfile {
        euint64 totalFacilityLimit;  // encrypted credit facility limit
        euint64 usedFacility;        // encrypted used facility
        euint64 reserveBalance;      // encrypted total reserve balance
        euint64 concentrationLimit;  // encrypted single debtor concentration limit
        euint64 defaultRate;         // encrypted historical default rate (bps)
        uint256 invoiceCount;
        bool active;
    }

    mapping(bytes32 => Invoice) private invoices;
    mapping(address => OriginatorProfile) private originators;
    mapping(address => euint64) private debtorExposure;    // encrypted per-debtor exposure
    mapping(address => euint64) private debtorCreditLimit; // encrypted debtor credit limit

    euint64 private _totalPortfolioOutstanding; // encrypted total outstanding
    euint64 private _totalReserves;             // encrypted total reserves
    euint64 private _platformFeeAccrued;        // encrypted platform fees
    euint64 private _defaultPoolBalance;        // encrypted default protection pool

    event InvoiceSubmitted(bytes32 indexed invoiceId, address originator, address debtor);
    event InvoiceVerified(bytes32 indexed invoiceId);
    event InvoiceFunded(bytes32 indexed invoiceId);
    event InvoiceCollected(bytes32 indexed invoiceId);
    event InvoiceDefaulted(bytes32 indexed invoiceId);
    event ReserveReleased(address indexed originator);
    event FacilityAdjusted(address indexed originator);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FACTOR_ROLE, msg.sender);
        _totalPortfolioOutstanding = FHE.asEuint64(0);
        _totalReserves = FHE.asEuint64(0);
        _platformFeeAccrued = FHE.asEuint64(0);
        _defaultPoolBalance = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioOutstanding);
        FHE.allowThis(_totalReserves);
        FHE.allowThis(_platformFeeAccrued);
        FHE.allowThis(_defaultPoolBalance);
    }

    function onboardOriginator(
        address orig,
        externalEuint64 encFacilityLimit, bytes calldata flProof,
        externalEuint64 encConcentrationLimit, bytes calldata clProof
    ) external onlyRole(FACTOR_ROLE) {
        euint64 facilityLimit = FHE.fromExternal(encFacilityLimit, flProof);
        euint64 concentrationLimit = FHE.fromExternal(encConcentrationLimit, clProof);
        OriginatorProfile storage profile = originators[orig];
        profile.totalFacilityLimit = facilityLimit;
        profile.concentrationLimit = concentrationLimit;
        profile.usedFacility = FHE.asEuint64(0);
        profile.reserveBalance = FHE.asEuint64(0);
        profile.defaultRate = FHE.asEuint64(0);
        profile.active = true;
        FHE.allowThis(facilityLimit);
        FHE.allow(facilityLimit, orig);
        FHE.allowThis(concentrationLimit);
        FHE.allow(concentrationLimit, orig);
        FHE.allowThis(profile.usedFacility);
        FHE.allow(profile.usedFacility, orig);
        FHE.allowThis(profile.reserveBalance);
        FHE.allow(profile.reserveBalance, orig);
        FHE.allowThis(profile.defaultRate);
        _grantRole(ORIGINATOR_ROLE, orig);
        emit FacilityAdjusted(orig);
    }

    function submitInvoice(
        address debtor,
        FactoringType factoringType,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint64 encAdvanceRate, bytes calldata arProof,
        uint256 invoiceDate,
        uint256 dueDate
    ) external onlyRole(ORIGINATOR_ROLE) returns (bytes32 invoiceId) {
        require(dueDate > block.timestamp, "Due date passed");
        OriginatorProfile storage profile = originators[msg.sender];
        require(profile.active, "Originator not active");

        euint64 faceValue = FHE.fromExternal(encFaceValue, fvProof);
        euint64 advanceRateBps = FHE.fromExternal(encAdvanceRate, arProof);
        euint64 advanceAmount = FHE.div(FHE.mul(faceValue, advanceRateBps), 10000);
        euint64 reserveAmount = FHE.sub(faceValue, advanceAmount);
        euint64 discountFee = FHE.div(FHE.mul(faceValue, 250), 10000); // 2.5%

        invoiceId = keccak256(abi.encodePacked(msg.sender, debtor, invoiceDate, block.timestamp));

        Invoice storage _s0 = invoices[invoiceId];
        _s0.originator = msg.sender;
        _s0.debtor = debtor;
        _s0.factoringType = factoringType;
        _s0.status = InvoiceStatus.SUBMITTED;
        _s0.faceValue = faceValue;
        _s0.advanceAmount = advanceAmount;
        _s0.reserveAmount = reserveAmount;
        _s0.discountFee = discountFee;
        _s0.debtorCreditScore = FHE.asEuint64(0);
        _s0.advanceRateBps = advanceRateBps;
        _s0.invoiceDate = invoiceDate;
        _s0.dueDate = dueDate;
        _s0.fundedAt = 0;
        _s0.verified = false;

        FHE.allowThis(faceValue);
        FHE.allow(faceValue, msg.sender);
        FHE.allowThis(advanceAmount);
        FHE.allow(advanceAmount, msg.sender);
        FHE.allowThis(reserveAmount);
        FHE.allow(reserveAmount, msg.sender);
        FHE.allowThis(discountFee);
        FHE.allow(discountFee, msg.sender);
        FHE.allowThis(advanceRateBps);
        FHE.allowThis(invoices[invoiceId].debtorCreditScore);

        emit InvoiceSubmitted(invoiceId, msg.sender, debtor);
    }

    function verifyInvoice(
        bytes32 invoiceId,
        externalEuint64 encDebtorScore, bytes calldata dsProof
    ) external onlyRole(VERIFIER_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.SUBMITTED, "Not in submitted state");
        euint64 debtorScore = FHE.fromExternal(encDebtorScore, dsProof);
        inv.debtorCreditScore = debtorScore;
        inv.status = InvoiceStatus.VERIFIED;
        inv.verified = true;
        FHE.allowThis(debtorScore);
        FHE.allow(debtorScore, inv.originator);
        emit InvoiceVerified(invoiceId);
    }

    function fundInvoice(bytes32 invoiceId) external onlyRole(FACTOR_ROLE) nonReentrant {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.VERIFIED, "Not verified");

        euint64 netAdvance = FHE.sub(inv.advanceAmount, inv.discountFee);
        inv.status = InvoiceStatus.FUNDED;
        inv.fundedAt = block.timestamp;

        OriginatorProfile storage profile = originators[inv.originator];
        profile.usedFacility = FHE.add(profile.usedFacility, inv.advanceAmount);
        profile.reserveBalance = FHE.add(profile.reserveBalance, inv.reserveAmount);

        _totalPortfolioOutstanding = FHE.add(_totalPortfolioOutstanding, inv.faceValue);
        _totalReserves = FHE.add(_totalReserves, inv.reserveAmount);
        _platformFeeAccrued = FHE.add(_platformFeeAccrued, inv.discountFee);

        debtorExposure[inv.debtor] = FHE.add(debtorExposure[inv.debtor], inv.faceValue);

        FHE.allowThis(profile.usedFacility);
        FHE.allow(profile.usedFacility, inv.originator);
        FHE.allowThis(profile.reserveBalance);
        FHE.allow(profile.reserveBalance, inv.originator);
        FHE.allowThis(_totalPortfolioOutstanding);
        FHE.allowThis(_totalReserves);
        FHE.allowThis(_platformFeeAccrued);
        FHE.allowThis(debtorExposure[inv.debtor]);
        FHE.allowTransient(netAdvance, inv.originator);

        emit InvoiceFunded(invoiceId);
    }

    function markCollected(bytes32 invoiceId) external onlyRole(FACTOR_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.FUNDED, "Not funded");
        inv.status = InvoiceStatus.COLLECTED;

        OriginatorProfile storage profile = originators[inv.originator];
        profile.usedFacility = FHE.sub(profile.usedFacility, inv.advanceAmount);
        profile.reserveBalance = FHE.sub(profile.reserveBalance, inv.reserveAmount);
        _totalPortfolioOutstanding = FHE.sub(_totalPortfolioOutstanding, inv.faceValue);
        _totalReserves = FHE.sub(_totalReserves, inv.reserveAmount);

        FHE.allowThis(profile.usedFacility);
        FHE.allow(profile.usedFacility, inv.originator);
        FHE.allowThis(profile.reserveBalance);
        FHE.allow(profile.reserveBalance, inv.originator);
        FHE.allowThis(_totalPortfolioOutstanding);
        FHE.allowThis(_totalReserves);

        FHE.allowTransient(inv.reserveAmount, inv.originator);
        emit InvoiceCollected(invoiceId);
        emit ReserveReleased(inv.originator);
    }

    function markDefaulted(bytes32 invoiceId) external onlyRole(FACTOR_ROLE) {
        Invoice storage inv = invoices[invoiceId];
        require(inv.status == InvoiceStatus.FUNDED, "Not funded");
        require(block.timestamp > inv.dueDate + 30 days, "Grace period active");
        inv.status = InvoiceStatus.DEFAULTED;
        _defaultPoolBalance = FHE.add(_defaultPoolBalance, inv.advanceAmount);
        FHE.allowThis(_defaultPoolBalance);
        emit InvoiceDefaulted(invoiceId);
    }

    function allowPortfolioView(address viewer) external onlyRole(FACTOR_ROLE) {
        FHE.allow(_totalPortfolioOutstanding, viewer);
        FHE.allow(_totalReserves, viewer);
        FHE.allow(_platformFeeAccrued, viewer);
    }
}
