// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCreditDefaultSwapRegistry
/// @notice Encrypted CDS registry: hidden notional amounts, private spread payments,
///         confidential credit event determinations, and encrypted settlement mechanics.
contract PrivateCreditDefaultSwapRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CDSStatus { Active, Triggered, Settled, Expired }
    enum CreditEventType { Bankruptcy, FailureToPay, Restructuring, RepudiationMoratorium }

    struct CreditDefaultSwap {
        address protectionBuyer;
        address protectionSeller;
        string referenceEntity;
        string cdsRef;
        euint64 notionalAmountUSD;     // encrypted notional
        euint64 spreadBps;             // encrypted CDS spread
        euint64 premiumPaidUSD;        // encrypted premium paid
        euint64 recoveryRateBps;       // encrypted recovery rate
        euint64 payoutAmountUSD;       // encrypted payout
        CDSStatus status;
        uint256 tradeDate;
        uint256 maturityDate;
    }

    struct PremiumPayment {
        uint256 cdsId;
        euint64 amount;                // encrypted payment
        uint256 paidAt;
    }

    mapping(uint256 => CreditDefaultSwap) private swaps;
    mapping(uint256 => PremiumPayment) private premiumPayments;
    mapping(address => bool) public isCDSDealer;

    uint256 public swapCount;
    uint256 public paymentCount;
    euint64 private _totalNotionalUSD;
    euint64 private _totalPremiumCollectedUSD;
    euint64 private _totalPayoutsUSD;

    event CDSRegistered(uint256 indexed id, string referenceEntity);
    event PremiumPaid(uint256 indexed paymentId, uint256 cdsId);
    event CreditEventTriggered(uint256 indexed cdsId, CreditEventType eventType);
    event CDSSettled(uint256 indexed cdsId, uint256 settledAt);

    modifier onlyCDSDealer() {
        require(isCDSDealer[msg.sender] || msg.sender == owner(), "Not CDS dealer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalNotionalUSD = FHE.asEuint64(0);
        _totalPremiumCollectedUSD = FHE.asEuint64(0);
        _totalPayoutsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalNotionalUSD);
        FHE.allowThis(_totalPremiumCollectedUSD);
        FHE.allowThis(_totalPayoutsUSD);
        isCDSDealer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addCDSDealer(address d) external onlyOwner { isCDSDealer[d] = true; }

    function registerCDS(
        address protectionSeller, string calldata referenceEntity, string calldata cdsRef,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encSpread,   bytes calldata sProof,
        externalEuint64 encRecovery, bytes calldata rProof,
        uint256 maturityDays
    ) external onlyCDSDealer whenNotPaused returns (uint256 id) {
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 spread   = FHE.fromExternal(encSpread, sProof);
        euint64 recovery = FHE.fromExternal(encRecovery, rProof);
        id = swapCount++;
        swaps[id] = CreditDefaultSwap({
            protectionBuyer: msg.sender, protectionSeller: protectionSeller,
            referenceEntity: referenceEntity, cdsRef: cdsRef, notionalAmountUSD: notional,
            spreadBps: spread, premiumPaidUSD: FHE.asEuint64(0), recoveryRateBps: recovery,
            payoutAmountUSD: FHE.asEuint64(0), status: CDSStatus.Active,
            tradeDate: block.timestamp, maturityDate: block.timestamp + maturityDays * 1 days
        });
        _totalNotionalUSD = FHE.add(_totalNotionalUSD, notional);
        FHE.allowThis(swaps[id].notionalAmountUSD); FHE.allow(swaps[id].notionalAmountUSD, msg.sender); FHE.allow(swaps[id].notionalAmountUSD, protectionSeller);
        FHE.allowThis(swaps[id].spreadBps); FHE.allow(swaps[id].spreadBps, msg.sender); FHE.allow(swaps[id].spreadBps, protectionSeller);
        FHE.allowThis(swaps[id].premiumPaidUSD); FHE.allow(swaps[id].premiumPaidUSD, msg.sender);
        FHE.allowThis(swaps[id].recoveryRateBps);
        FHE.allowThis(swaps[id].payoutAmountUSD); FHE.allow(swaps[id].payoutAmountUSD, msg.sender);
        FHE.allowThis(_totalNotionalUSD);
        emit CDSRegistered(id, referenceEntity);
    }

    function payPremium(uint256 cdsId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant whenNotPaused {
        CreditDefaultSwap storage cds = swaps[cdsId];
        require(cds.status == CDSStatus.Active && msg.sender == cds.protectionBuyer, "Cannot pay");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        cds.premiumPaidUSD = FHE.add(cds.premiumPaidUSD, amount);
        _totalPremiumCollectedUSD = FHE.add(_totalPremiumCollectedUSD, amount);
        uint256 payId = paymentCount++;
        premiumPayments[payId] = PremiumPayment({ cdsId: cdsId, amount: amount, paidAt: block.timestamp });
        FHE.allowThis(cds.premiumPaidUSD); FHE.allow(cds.premiumPaidUSD, cds.protectionBuyer);
        FHE.allowThis(premiumPayments[payId].amount); FHE.allow(premiumPayments[payId].amount, msg.sender);
        FHE.allowThis(_totalPremiumCollectedUSD);
        emit PremiumPaid(payId, cdsId);
    }

    function triggerCreditEvent(uint256 cdsId, CreditEventType eventType) external onlyCDSDealer nonReentrant {
        CreditDefaultSwap storage cds = swaps[cdsId];
        require(cds.status == CDSStatus.Active, "Not active");
        cds.status = CDSStatus.Triggered;
        // Payout = notional * (1 - recoveryRate) / 10000
        euint64 lossPct = FHE.sub(FHE.asEuint64(10000), cds.recoveryRateBps);
        euint64 payout  = FHE.div(FHE.mul(cds.notionalAmountUSD, lossPct), 10000);
        cds.payoutAmountUSD = payout;
        _totalPayoutsUSD = FHE.add(_totalPayoutsUSD, payout);
        FHE.allowThis(cds.payoutAmountUSD); FHE.allow(cds.payoutAmountUSD, cds.protectionBuyer); FHE.allow(cds.payoutAmountUSD, cds.protectionSeller);
        FHE.allowThis(_totalPayoutsUSD);
        emit CreditEventTriggered(cdsId, eventType);
    }

    function settleCDS(uint256 cdsId) external onlyCDSDealer nonReentrant {
        CreditDefaultSwap storage cds = swaps[cdsId];
        require(cds.status == CDSStatus.Triggered, "Not triggered");
        cds.status = CDSStatus.Settled;
        emit CDSSettled(cdsId, block.timestamp);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalNotionalUSD, viewer);
        FHE.allow(_totalPremiumCollectedUSD, viewer);
        FHE.allow(_totalPayoutsUSD, viewer);
    }
}
