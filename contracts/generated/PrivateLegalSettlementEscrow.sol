// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateLegalSettlementEscrow
/// @notice Encrypted legal settlement escrow: hidden settlement amounts, confidential
///         structured payment schedules, private confidentiality breach penalties,
///         and encrypted mediator fee distributions.
contract PrivateLegalSettlementEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DisputeType { PersonalInjury, CommercialDispute, IntellectualProperty, EmploymentLaw, ClassAction }
    enum SettlementStatus { NegotiationPhase, Agreed, PartiallyPaid, FullyPaid, Breached }

    struct LegalSettlement {
        address plaintiff;
        address defendant;
        address mediator;
        DisputeType disputeType;
        string caseRef;
        euint64 totalSettlementUSD;    // encrypted settlement amount
        euint64 paidToDateUSD;         // encrypted paid so far
        euint64 mediatorFeeUSD;        // encrypted mediator fee
        euint64 confidentialityPenaltyUSD; // encrypted breach penalty
        euint16 structuredPaymentBps;  // encrypted structured payment schedule
        SettlementStatus status;
        uint256 agreedAt;
        uint256 completionDeadline;
    }

    mapping(uint256 => LegalSettlement) private settlements;
    mapping(address => bool) public isLegalMediator;
    mapping(address => bool) public isCourtOfficer;

    uint256 public settlementCount;
    euint64 private _totalSettledValueUSD;
    euint64 private _totalMediatorFeesUSD;

    event SettlementAgreed(uint256 indexed id, DisputeType disputeType);
    event PaymentInstallmentMade(uint256 indexed id, uint256 madeAt);
    event SettlementBreached(uint256 indexed id);

    modifier onlyLegalMediator() {
        require(isLegalMediator[msg.sender] || msg.sender == owner(), "Not legal mediator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSettledValueUSD = FHE.asEuint64(0);
        _totalMediatorFeesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSettledValueUSD);
        FHE.allowThis(_totalMediatorFeesUSD);
        isLegalMediator[msg.sender] = true;
        isCourtOfficer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addMediator(address m) external onlyOwner { isLegalMediator[m] = true; }
    function addCourtOfficer(address co) external onlyOwner { isCourtOfficer[co] = true; }

    function recordSettlement(
        address plaintiff, address defendant, DisputeType disputeType, string calldata caseRef,
        externalEuint64 encSettlementAmt, bytes calldata saProof,
        externalEuint64 encMediatorFee, bytes calldata mfProof,
        externalEuint64 encConfPenalty, bytes calldata cpProof,
        externalEuint16 encStructuredBps, bytes calldata sbProof,
        uint256 completionDays
    ) external onlyLegalMediator whenNotPaused returns (uint256 id) {
        euint64 settlementAmt = FHE.fromExternal(encSettlementAmt, saProof);
        euint64 mediatorFee = FHE.fromExternal(encMediatorFee, mfProof);
        euint64 confPenalty = FHE.fromExternal(encConfPenalty, cpProof);
        euint16 structuredBps = FHE.fromExternal(encStructuredBps, sbProof);
        id = settlementCount++;
        settlements[id] = LegalSettlement({
            plaintiff: plaintiff, defendant: defendant, mediator: msg.sender,
            disputeType: disputeType, caseRef: caseRef, totalSettlementUSD: settlementAmt,
            paidToDateUSD: FHE.asEuint64(0), mediatorFeeUSD: mediatorFee,
            confidentialityPenaltyUSD: confPenalty, structuredPaymentBps: structuredBps,
            status: SettlementStatus.Agreed, agreedAt: block.timestamp,
            completionDeadline: block.timestamp + completionDays * 1 days
        });
        _totalSettledValueUSD = FHE.add(_totalSettledValueUSD, settlementAmt);
        _totalMediatorFeesUSD = FHE.add(_totalMediatorFeesUSD, mediatorFee);
        FHE.allowThis(settlements[id].totalSettlementUSD); FHE.allow(settlements[id].totalSettlementUSD, plaintiff); FHE.allow(settlements[id].totalSettlementUSD, defendant);
        FHE.allowThis(settlements[id].paidToDateUSD); FHE.allow(settlements[id].paidToDateUSD, plaintiff);
        FHE.allowThis(settlements[id].mediatorFeeUSD); FHE.allow(settlements[id].mediatorFeeUSD, msg.sender);
        FHE.allowThis(settlements[id].confidentialityPenaltyUSD);
        FHE.allowThis(settlements[id].structuredPaymentBps); FHE.allow(settlements[id].structuredPaymentBps, defendant);
        FHE.allowThis(_totalSettledValueUSD);
        FHE.allowThis(_totalMediatorFeesUSD);
        emit SettlementAgreed(id, disputeType);
    }

    function makePaymentInstallment(
        uint256 settlementId,
        externalEuint64 encInstallment, bytes calldata proof
    ) external nonReentrant {
        LegalSettlement storage s = settlements[settlementId];
        require(msg.sender == s.defendant, "Not defendant");
        require(s.status == SettlementStatus.Agreed || s.status == SettlementStatus.PartiallyPaid, "Not payable");
        euint64 installment = FHE.fromExternal(encInstallment, proof);
        s.paidToDateUSD = FHE.add(s.paidToDateUSD, installment);
        ebool fullyPaid = FHE.ge(s.paidToDateUSD, s.totalSettlementUSD);
        if (FHE.isInitialized(fullyPaid)) s.status = SettlementStatus.FullyPaid;
        else s.status = SettlementStatus.PartiallyPaid;
        FHE.allowThis(s.paidToDateUSD); FHE.allow(s.paidToDateUSD, s.plaintiff); FHE.allow(s.paidToDateUSD, s.mediator);
        emit PaymentInstallmentMade(settlementId, block.timestamp);
    }

    function declareBreach(uint256 settlementId) external onlyLegalMediator {
        settlements[settlementId].status = SettlementStatus.Breached;
        emit SettlementBreached(settlementId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalSettledValueUSD, viewer);
        FHE.allow(_totalMediatorFeesUSD, viewer);
    }
}
