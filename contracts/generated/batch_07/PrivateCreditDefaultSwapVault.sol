// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCreditDefaultSwapVault
/// @notice CDS marketplace where notional amounts, spread rates, premium payments,
///         and credit event payouts are fully encrypted between protection buyer/seller.
contract PrivateCreditDefaultSwapVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ReferenceEntityRating { AAA, AA, A, BBB, BB, B, CCC, DEFAULT }
    enum CreditEventType { BANKRUPTCY, FAILURE_TO_PAY, RESTRUCTURING, REPUDIATION, OBLIGATION_ACCELERATION }

    struct CDSContract {
        string  referenceEntity;
        address protectionBuyer;
        address protectionSeller;
        ReferenceEntityRating rating;
        euint64 notionalUSD;          // encrypted notional principal
        euint64 spreadBps;            // encrypted CDS spread in bps
        euint64 quarterlyPremiumUSD;  // encrypted quarterly payment
        euint64 totalPremiumsPaid;    // encrypted cumulative paid
        euint64 recoveryRateBps;      // encrypted assumed recovery
        euint64 potentialPayoutUSD;   // encrypted max payout = notional*(1-recovery)
        euint32 tenorMonths;          // encrypted tenor
        uint256 inceptionDate;
        uint256 maturityDate;
        bool    creditEventOccurred;
        bool    settled;
        bool    active;
    }

    struct CreditEvent {
        uint256 cdsId;
        CreditEventType eventType;
        euint64 settlementAmountUSD;  // encrypted final payout
        euint64 actualRecoveryBps;    // encrypted actual recovery at default
        address determinationCommittee;
        uint256 eventDate;
        bool    confirmed;
    }

    mapping(uint256 => CDSContract) private cdsContracts;
    mapping(uint256 => CreditEvent) private creditEvents;
    mapping(address => bool) public isDetermCommittee;
    mapping(address => bool) public isCDSDealer;
    uint256 public cdsCount;
    uint256 public eventCount;
    euint64 private _totalNotionalOutstanding;
    euint64 private _totalPremiumsCollected;
    euint64 private _totalCreditEventPayouts;

    event CDSExecuted(uint256 indexed cdsId, string entity);
    event PremiumPaid(uint256 indexed cdsId);
    event CreditEventDeclared(uint256 indexed cdsId, CreditEventType eventType);
    event CDSSettled(uint256 indexed cdsId);

    constructor() Ownable(msg.sender) {
        _totalNotionalOutstanding = FHE.asEuint64(0);
        _totalPremiumsCollected   = FHE.asEuint64(0);
        _totalCreditEventPayouts  = FHE.asEuint64(0);
        FHE.allowThis(_totalNotionalOutstanding);
        FHE.allowThis(_totalPremiumsCollected);
        FHE.allowThis(_totalCreditEventPayouts);
        isCDSDealer[msg.sender]        = true;
        isDetermCommittee[msg.sender]  = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addDealer(address d) external onlyOwner { isCDSDealer[d] = true; }
    function addCommittee(address c) external onlyOwner { isDetermCommittee[c] = true; }

    function executeCDS(
        string calldata entity,
        address buyer,
        address seller,
        ReferenceEntityRating rating,
        externalEuint64 encNotional,  bytes calldata notProof,
        externalEuint64 encSpread,    bytes calldata sprProof,
        externalEuint64 encRecovery,  bytes calldata recProof,
        externalEuint32 encTenor,     bytes calldata tenProof
    ) external whenNotPaused returns (uint256 cdsId) {
        require(isCDSDealer[msg.sender], "Not dealer");
        euint64 notional  = FHE.fromExternal(encNotional, notProof);
        euint64 spread    = FHE.fromExternal(encSpread,   sprProof);
        euint64 recovery  = FHE.fromExternal(encRecovery, recProof);
        euint32 tenor     = FHE.fromExternal(encTenor,    tenProof);

        // Quarterly premium = notional * spread / 4 / 10000
        euint64 quarterly = FHE.div(FHE.mul(notional, spread), 40000);
        // Payout = notional * (10000 - recovery) / 10000
        euint64 payout    = FHE.div(FHE.mul(notional, FHE.sub(FHE.asEuint64(10000), recovery)), 10000);

        cdsId = cdsCount++;
        CDSContract storage _s0 = cdsContracts[cdsId];
        _s0.referenceEntity = entity;
        _s0.protectionBuyer = buyer;
        _s0.protectionSeller = seller;
        _s0.rating = rating;
        _s0.notionalUSD = notional;
        _s0.spreadBps = spread;
        _s0.quarterlyPremiumUSD = quarterly;
        _s0.totalPremiumsPaid = FHE.asEuint64(0);
        _s0.recoveryRateBps = recovery;
        _s0.potentialPayoutUSD = payout;
        _s0.tenorMonths = tenor;
        _s0.inceptionDate = block.timestamp;
        _s0.maturityDate = block.timestamp + 30 days * 12;
        _s0.creditEventOccurred = false;
        _s0.settled = false;
        _s0.active = true;

        _totalNotionalOutstanding = FHE.add(_totalNotionalOutstanding, notional);

        FHE.allowThis(cdsContracts[cdsId].notionalUSD);
        FHE.allow(cdsContracts[cdsId].notionalUSD, buyer);
        FHE.allow(cdsContracts[cdsId].notionalUSD, seller);
        FHE.allowThis(cdsContracts[cdsId].spreadBps);
        FHE.allow(cdsContracts[cdsId].spreadBps, buyer);
        FHE.allow(cdsContracts[cdsId].spreadBps, seller);
        FHE.allowThis(cdsContracts[cdsId].quarterlyPremiumUSD);
        FHE.allow(cdsContracts[cdsId].quarterlyPremiumUSD, buyer);
        FHE.allowThis(cdsContracts[cdsId].totalPremiumsPaid);
        FHE.allow(cdsContracts[cdsId].totalPremiumsPaid, buyer);
        FHE.allowThis(cdsContracts[cdsId].recoveryRateBps);
        FHE.allow(cdsContracts[cdsId].recoveryRateBps, seller);
        FHE.allowThis(cdsContracts[cdsId].potentialPayoutUSD);
        FHE.allow(cdsContracts[cdsId].potentialPayoutUSD, buyer);
        FHE.allowThis(cdsContracts[cdsId].tenorMonths);
        FHE.allowThis(_totalNotionalOutstanding);
        emit CDSExecuted(cdsId, entity);
    }

    function payQuarterlyPremium(uint256 cdsId) external nonReentrant whenNotPaused {
        require(cdsContracts[cdsId].protectionBuyer == msg.sender, "Not buyer");
        require(cdsContracts[cdsId].active && !cdsContracts[cdsId].creditEventOccurred, "Invalid state");

        euint64 premium = cdsContracts[cdsId].quarterlyPremiumUSD;
        cdsContracts[cdsId].totalPremiumsPaid = FHE.add(
            cdsContracts[cdsId].totalPremiumsPaid, premium
        );
        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, premium);

        FHE.allowThis(cdsContracts[cdsId].totalPremiumsPaid);
        FHE.allow(cdsContracts[cdsId].totalPremiumsPaid, msg.sender);
        FHE.allowThis(_totalPremiumsCollected);
        emit PremiumPaid(cdsId);
    }

    function declareCreditEvent(
        uint256 cdsId,
        CreditEventType eventType,
        externalEuint64 encActualRecovery, bytes calldata proof
    ) external returns (uint256 eventId) {
        require(isDetermCommittee[msg.sender], "Not committee");
        require(cdsContracts[cdsId].active && !cdsContracts[cdsId].creditEventOccurred, "Invalid");

        euint64 actualRecovery = FHE.fromExternal(encActualRecovery, proof);
        euint64 settlement     = FHE.div(
            FHE.mul(cdsContracts[cdsId].notionalUSD,
                    FHE.sub(FHE.asEuint64(10000), actualRecovery)),
            10000
        );

        cdsContracts[cdsId].creditEventOccurred = true;
        eventId = eventCount++;
        creditEvents[eventId] = CreditEvent({
            cdsId: cdsId,
            eventType: eventType,
            settlementAmountUSD: settlement,
            actualRecoveryBps: actualRecovery,
            determinationCommittee: msg.sender,
            eventDate: block.timestamp,
            confirmed: true
        });
        _totalCreditEventPayouts = FHE.add(_totalCreditEventPayouts, settlement);

        FHE.allowThis(creditEvents[eventId].settlementAmountUSD);
        FHE.allow(creditEvents[eventId].settlementAmountUSD, cdsContracts[cdsId].protectionBuyer);
        FHE.allow(creditEvents[eventId].settlementAmountUSD, cdsContracts[cdsId].protectionSeller);
        FHE.allowThis(creditEvents[eventId].actualRecoveryBps);
        FHE.allowThis(_totalCreditEventPayouts);
        emit CreditEventDeclared(cdsId, eventType);
    }

    function settleCDS(uint256 cdsId) external {
        require(isDetermCommittee[msg.sender], "Not committee");
        cdsContracts[cdsId].settled = true;
        cdsContracts[cdsId].active  = false;
        _totalNotionalOutstanding   = FHE.sub(
            _totalNotionalOutstanding, cdsContracts[cdsId].notionalUSD
        );
        FHE.allowThis(_totalNotionalOutstanding);
        emit CDSSettled(cdsId);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalNotionalOutstanding, viewer);
        FHE.allow(_totalPremiumsCollected,   viewer);
        FHE.allow(_totalCreditEventPayouts,  viewer);
    }
}
