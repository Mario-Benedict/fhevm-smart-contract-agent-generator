// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCatastropheRiskModelingPool
/// @notice CAT bond and ILS (Insurance-Linked Securities) pool with encrypted
///         modeled expected losses, trigger thresholds, attachment points, and
///         confidential sponsor loss experience reporting.
contract PrivateCatastropheRiskModelingPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum PerilType { HURRICANE, EARTHQUAKE, FLOOD, WILDFIRE, TORNADO, PANDEMIC, CYBER_CAT }
    enum TriggerType { INDEMNITY, INDUSTRY_INDEX, PARAMETRIC, MODELED_LOSS, HYBRID }
    enum BondStatus { ISSUANCE, RISK_PERIOD, TRIGGERED, PARTIAL_LOSS, TOTAL_LOSS, MATURED }

    struct CATBond {
        PerilType peril;
        TriggerType trigger;
        BondStatus status;
        euint64 principalUSD;            // encrypted principal at risk
        euint64 attachmentPoint;         // encrypted attachment threshold
        euint64 exhaustionPoint;         // encrypted full loss trigger
        euint64 couponRateBps;           // encrypted spread + risk free
        euint64 expectedLossBps;         // encrypted modeled expected loss
        euint64 probOfAttachmentBps;     // encrypted probability of attachment
        euint64 payoutToSponsors;        // encrypted actual payout if triggered
        euint64 returnToInvestors;       // encrypted return of principal portion
        euint64 reserveEscrow;           // encrypted escrow balance
        uint256 issuanceDate;
        uint256 riskPeriodEnd;
        uint256 maturityDate;
        bool triggered;
    }

    struct InvestorAllocation {
        euint64 investedAmount;          // encrypted investment
        euint64 expectedCoupon;          // encrypted coupon income
        euint64 principalAtRisk;         // encrypted principal at risk
        euint64 currentValue;            // encrypted MTM value
        bool active;
    }

    struct CATEvent {
        bytes32 bondId;
        PerilType peril;
        euint64 industryLossEstimate;    // encrypted industry loss (USD)
        euint64 sponsorLossEstimate;     // encrypted sponsor's modeled loss
        euint64 parametricMeasurement;  // encrypted wind speed/magnitude
        euint64 triggerConfidence;       // encrypted trigger confidence level (bps)
        uint256 eventDate;
        bool finalSettlement;
    }

    mapping(bytes32 => CATBond) private catBonds;
    mapping(bytes32 => mapping(address => InvestorAllocation)) private allocations;
    mapping(bytes32 => CATEvent[]) private catEvents;
    mapping(bytes32 => address[]) private bondInvestors;
    mapping(address => bool) public authorizedSponsor;

    euint64 private _totalPrincipalAtRisk;    // encrypted total ILS AUM
    euint64 private _totalCouponsPaid;        // encrypted total coupons paid
    euint64 private _totalLossesPaid;         // encrypted total losses paid out

    event CATBondIssued(bytes32 indexed bondId, PerilType peril, TriggerType trigger);
    event InvestorAllocated(bytes32 indexed bondId, address indexed investor);
    event CATEventReported(bytes32 indexed eventId, bytes32 indexed bondId);
    event TriggerConfirmed(bytes32 indexed bondId);
    event BondMatured(bytes32 indexed bondId);

    constructor() Ownable(msg.sender) {
        _totalPrincipalAtRisk = FHE.asEuint64(0);
        _totalCouponsPaid = FHE.asEuint64(0);
        _totalLossesPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalPrincipalAtRisk);
        FHE.allowThis(_totalCouponsPaid);
        FHE.allowThis(_totalLossesPaid);
    }

    function issueCATBond(
        PerilType peril,
        TriggerType trigger,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encAttachment, bytes calldata aProof,
        externalEuint64 encExhaustion, bytes calldata eProof,
        externalEuint64 encCoupon, bytes calldata cProof,
        externalEuint64 encEL, bytes calldata elProof,
        externalEuint64 encPOA, bytes calldata poaProof,
        uint256 riskPeriodEnd,
        uint256 maturityDate
    ) external onlyOwner returns (bytes32 bondId) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 attachment = FHE.fromExternal(encAttachment, aProof);
        euint64 exhaustion = FHE.fromExternal(encExhaustion, eProof);
        euint64 coupon = FHE.fromExternal(encCoupon, cProof);
        euint64 el = FHE.fromExternal(encEL, elProof);
        euint64 poa = FHE.fromExternal(encPOA, poaProof);

        bondId = keccak256(abi.encodePacked(peril, trigger, riskPeriodEnd, block.timestamp));
        CATBond storage _s0 = catBonds[bondId];
        _s0.peril = peril;
        _s0.trigger = trigger;
        _s0.status = BondStatus.ISSUANCE;
        _s0.principalUSD = principal;
        _s0.attachmentPoint = attachment;
        _s0.exhaustionPoint = exhaustion;
        _s0.couponRateBps = coupon;
        _s0.expectedLossBps = el;
        _s0.probOfAttachmentBps = poa;
        _s0.payoutToSponsors = FHE.asEuint64(0);
        _s0.returnToInvestors = principal;
        _s0.reserveEscrow = principal;
        _s0.issuanceDate = block.timestamp;
        _s0.riskPeriodEnd = riskPeriodEnd;
        _s0.maturityDate = maturityDate;
        _s0.triggered = false;

        _totalPrincipalAtRisk = FHE.add(_totalPrincipalAtRisk, principal);

        FHE.allowThis(principal); FHE.allowThis(attachment); FHE.allowThis(exhaustion);
        FHE.allowThis(coupon); FHE.allowThis(el); FHE.allowThis(poa);
        FHE.allowThis(catBonds[bondId].payoutToSponsors);
        FHE.allowThis(catBonds[bondId].returnToInvestors);
        FHE.allowThis(catBonds[bondId].reserveEscrow);
        FHE.allowThis(_totalPrincipalAtRisk);

        emit CATBondIssued(bondId, peril, trigger);
    }

    function allocateToInvestor(
        bytes32 bondId,
        address investor,
        externalEuint64 encInvestment, bytes calldata invProof
    ) external onlyOwner {
        CATBond storage bond = catBonds[bondId];
        euint64 investment = FHE.fromExternal(encInvestment, invProof);
        euint64 expectedCoupon = FHE.div(FHE.mul(investment, bond.couponRateBps), 10000);

        allocations[bondId][investor] = InvestorAllocation({
            investedAmount: investment, expectedCoupon: expectedCoupon,
            principalAtRisk: investment, currentValue: investment, active: true
        });
        bondInvestors[bondId].push(investor);

        FHE.allowThis(investment); FHE.allow(investment, investor);
        FHE.allowThis(expectedCoupon); FHE.allow(expectedCoupon, investor);
        FHE.allowThis(allocations[bondId][investor].currentValue);
        FHE.allow(allocations[bondId][investor].currentValue, investor);
        FHE.allowThis(allocations[bondId][investor].principalAtRisk);
        FHE.allow(allocations[bondId][investor].principalAtRisk, investor);
        emit InvestorAllocated(bondId, investor);
    }

    function reportCATEvent(
        bytes32 bondId,
        externalEuint64 encIndustryLoss, bytes calldata ilProof,
        externalEuint64 encSponsorLoss, bytes calldata slProof,
        externalEuint64 encParametric, bytes calldata prmProof,
        externalEuint64 encConfidence, bytes calldata confProof,
        uint256 eventDate
    ) external onlyOwner returns (bytes32 eventId) {
        euint64 industryLoss = FHE.fromExternal(encIndustryLoss, ilProof);
        euint64 sponsorLoss = FHE.fromExternal(encSponsorLoss, slProof);
        euint64 parametric = FHE.fromExternal(encParametric, prmProof);
        euint64 confidence = FHE.fromExternal(encConfidence, confProof);

        catEvents[bondId].push(CATEvent({
            bondId: bondId, peril: catBonds[bondId].peril,
            industryLossEstimate: industryLoss, sponsorLossEstimate: sponsorLoss,
            parametricMeasurement: parametric, triggerConfidence: confidence,
            eventDate: eventDate, finalSettlement: false
        }));

        FHE.allowThis(industryLoss); FHE.allowThis(sponsorLoss);
        FHE.allowThis(parametric); FHE.allowThis(confidence);

        eventId = keccak256(abi.encodePacked(bondId, eventDate));
        emit CATEventReported(eventId, bondId);
    }

    function confirmTriggerAndSettle(
        bytes32 bondId,
        externalEuint64 encPayoutAmount, bytes calldata payProof
    ) external onlyOwner {
        CATBond storage bond = catBonds[bondId];
        require(!bond.triggered, "Already triggered");
        euint64 payoutAmount = FHE.fromExternal(encPayoutAmount, payProof);
        bond.triggered = true;
        bond.payoutToSponsors = payoutAmount;
        bond.returnToInvestors = FHE.select(FHE.ge(bond.principalUSD, payoutAmount),
            FHE.sub(bond.principalUSD, payoutAmount), FHE.asEuint64(0));
        bond.reserveEscrow = bond.returnToInvestors;
        bond.status = BondStatus.TRIGGERED;
        _totalLossesPaid = FHE.add(_totalLossesPaid, payoutAmount);
        _totalPrincipalAtRisk = FHE.sub(_totalPrincipalAtRisk, bond.principalUSD);
        FHE.allowThis(payoutAmount); FHE.allowThis(bond.returnToInvestors);
        FHE.allowThis(bond.reserveEscrow);
        FHE.allowThis(_totalLossesPaid); FHE.allowThis(_totalPrincipalAtRisk);
        emit TriggerConfirmed(bondId);
    }

    function allowBondDataView(bytes32 bondId, address viewer) external onlyOwner {
        CATBond storage bond = catBonds[bondId];
        FHE.allow(bond.principalUSD, viewer);
        FHE.allow(bond.attachmentPoint, viewer);
        FHE.allow(bond.expectedLossBps, viewer);
        FHE.allow(bond.probOfAttachmentBps, viewer);
        FHE.allow(bond.couponRateBps, viewer);
        FHE.allow(_totalPrincipalAtRisk, viewer);
    }
}
