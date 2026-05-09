// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateElectricGridDemandResponse
/// @notice Grid demand response management: encrypted household/industrial load reduction bids,
///         encrypted grid congestion payments, encrypted carbon intensity tracking, and private DR event settlement.
contract PrivateElectricGridDemandResponse is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ParticipantType { RESIDENTIAL, COMMERCIAL, INDUSTRIAL, AGGREGATOR }
    enum GridZone { NORTH, SOUTH, EAST, WEST, CENTRAL }

    struct DRParticipant {
        address participant;
        ParticipantType pType;
        GridZone zone;
        euint64 baselineKwh;         // encrypted baseline load
        euint64 maxReductionKwh;     // encrypted max curtailable load
        euint64 minPaymentPerKwh;    // encrypted minimum acceptable price
        euint64 totalEarned;         // encrypted lifetime DR earnings
        euint64 reliabilityScore;    // encrypted participant reliability 0-1000
        bool enrolled;
    }

    struct DREvent {
        GridZone zone;
        euint64 requiredReductionMwh; // encrypted required grid reduction
        euint64 clearingPricePerKwh;  // encrypted market clearing price
        euint64 totalAwardedReduction;// encrypted total awarded
        euint64 carbonIntensity;      // encrypted grid carbon intensity gCO2/kWh
        uint256 eventStart;
        uint256 eventEnd;
        bool settled;
    }

    struct DRBid {
        uint256 eventId;
        address participant;
        euint64 offeredReductionKwh;  // encrypted offered reduction
        euint64 bidPricePerKwh;       // encrypted bid price
        euint64 actualReductionKwh;   // encrypted verified reduction
        euint64 paymentUSD;           // encrypted payment awarded
        bool accepted;
        bool verified;
    }

    mapping(address => DRParticipant) private participants;
    mapping(uint256 => DREvent) private events;
    mapping(uint256 => DRBid[]) private bids;
    uint256 public eventCount;
    euint64 private _totalDRPayments;
    euint64 private _totalCarbonSaved;
    mapping(address => bool) public isGridOperator;
    mapping(address => bool) public isDRVerifier;

    event ParticipantEnrolled(address indexed p, ParticipantType pType, GridZone zone);
    event DREventCalled(uint256 indexed id, GridZone zone);
    event BidSubmitted(uint256 indexed eventId, uint256 bidIdx, address participant);
    event EventSettled(uint256 indexed eventId);
    event ReductionVerified(uint256 indexed eventId, uint256 bidIdx);

    constructor() Ownable(msg.sender) {
        _totalDRPayments = FHE.asEuint64(0);
        _totalCarbonSaved = FHE.asEuint64(0);
        FHE.allowThis(_totalDRPayments);
        FHE.allowThis(_totalCarbonSaved);
        isGridOperator[msg.sender] = true;
        isDRVerifier[msg.sender] = true;
    }

    function addOperator(address o) external onlyOwner { isGridOperator[o] = true; }
    function addVerifier(address v) external onlyOwner { isDRVerifier[v] = true; }

    function enroll(
        ParticipantType pType, GridZone zone,
        externalEuint64 encBaseline, bytes calldata bProof,
        externalEuint64 encMaxReduction, bytes calldata mrProof,
        externalEuint64 encMinPayment, bytes calldata mpProof
    ) external {
        euint64 baseline = FHE.fromExternal(encBaseline, bProof);
        euint64 maxReduction = FHE.fromExternal(encMaxReduction, mrProof);
        euint64 minPayment = FHE.fromExternal(encMinPayment, mpProof);
        participants[msg.sender].participant = msg.sender;
        participants[msg.sender].pType = pType;
        participants[msg.sender].zone = zone;
        participants[msg.sender].baselineKwh = baseline;
        participants[msg.sender].maxReductionKwh = maxReduction;
        participants[msg.sender].minPaymentPerKwh = minPayment;
        participants[msg.sender].totalEarned = FHE.asEuint64(0);
        participants[msg.sender].reliabilityScore = FHE.asEuint64(500);
        participants[msg.sender].enrolled = true;
        FHE.allowThis(participants[msg.sender].baselineKwh);
        FHE.allowThis(participants[msg.sender].maxReductionKwh);
        FHE.allowThis(participants[msg.sender].minPaymentPerKwh);
        FHE.allowThis(participants[msg.sender].totalEarned);
        FHE.allowThis(participants[msg.sender].reliabilityScore);
        FHE.allow(participants[msg.sender].totalEarned, msg.sender);
        emit ParticipantEnrolled(msg.sender, pType, zone);
    }

    function callDREvent(
        GridZone zone,
        externalEuint64 encRequired, bytes calldata rProof,
        externalEuint64 encCarbonIntensity, bytes calldata ciProof,
        uint256 eventStart, uint256 eventEnd
    ) external returns (uint256 id) {
        require(isGridOperator[msg.sender], "Not operator");
        euint64 required = FHE.fromExternal(encRequired, rProof);
        euint64 carbonIntensity = FHE.fromExternal(encCarbonIntensity, ciProof);
        id = eventCount++;
        events[id] = DREvent({
            zone: zone, requiredReductionMwh: required,
            clearingPricePerKwh: FHE.asEuint64(0), totalAwardedReduction: FHE.asEuint64(0),
            carbonIntensity: carbonIntensity, eventStart: eventStart, eventEnd: eventEnd, settled: false
        });
        FHE.allowThis(events[id].requiredReductionMwh);
        FHE.allowThis(events[id].clearingPricePerKwh);
        FHE.allowThis(events[id].totalAwardedReduction);
        FHE.allowThis(events[id].carbonIntensity);
        emit DREventCalled(id, zone);
    }

    function submitBid(
        uint256 eventId,
        externalEuint64 encOffered, bytes calldata oProof,
        externalEuint64 encBidPrice, bytes calldata bpProof
    ) external returns (uint256 bidIdx) {
        DRParticipant storage p = participants[msg.sender];
        require(p.enrolled, "Not enrolled");
        DREvent storage ev = events[eventId];
        require(block.timestamp < ev.eventStart && !ev.settled, "Not open");
        euint64 offered = FHE.fromExternal(encOffered, oProof);
        euint64 bidPrice = FHE.fromExternal(encBidPrice, bpProof);
        // Bid must be at or above participant's minimum
        ebool priceMet = FHE.ge(bidPrice, p.minPaymentPerKwh);
        euint64 actualOffer = FHE.select(priceMet, offered, FHE.asEuint64(0));
        bidIdx = bids[eventId].length;
        bids[eventId].push(DRBid({
            eventId: eventId, participant: msg.sender,
            offeredReductionKwh: actualOffer, bidPricePerKwh: bidPrice,
            actualReductionKwh: FHE.asEuint64(0), paymentUSD: FHE.asEuint64(0),
            accepted: false, verified: false
        }));
        FHE.allowThis(bids[eventId][bidIdx].offeredReductionKwh);
        FHE.allowThis(bids[eventId][bidIdx].bidPricePerKwh);
        FHE.allowThis(bids[eventId][bidIdx].paymentUSD);
        FHE.allow(bids[eventId][bidIdx].paymentUSD, msg.sender);
        emit BidSubmitted(eventId, bidIdx, msg.sender);
    }

    function clearEvent(
        uint256 eventId,
        externalEuint64 encClearingPrice, bytes calldata proof,
        uint256[] calldata acceptedBids
    ) external {
        require(isGridOperator[msg.sender], "Not operator");
        DREvent storage ev = events[eventId];
        euint64 clearingPrice = FHE.fromExternal(encClearingPrice, proof);
        ev.clearingPricePerKwh = clearingPrice;
        for (uint256 i = 0; i < acceptedBids.length; i++) {
            bids[eventId][acceptedBids[i]].accepted = true;
            ev.totalAwardedReduction = FHE.add(ev.totalAwardedReduction,
                bids[eventId][acceptedBids[i]].offeredReductionKwh);
        }
        FHE.allowThis(ev.clearingPricePerKwh);
        FHE.allowThis(ev.totalAwardedReduction);
    }

    function verifyReduction(
        uint256 eventId, uint256 bidIdx,
        externalEuint64 encActual, bytes calldata proof
    ) external {
        require(isDRVerifier[msg.sender], "Not verifier");
        DRBid storage bid = bids[eventId][bidIdx];
        require(bid.accepted && !bid.verified, "Not eligible");
        euint64 actual = FHE.fromExternal(encActual, proof);
        bid.actualReductionKwh = actual;
        bid.verified = true;
        DREvent storage ev = events[eventId];
        euint64 payment = FHE.mul(actual, ev.clearingPricePerKwh);
        bid.paymentUSD = payment;
        participants[bid.participant].totalEarned = FHE.add(participants[bid.participant].totalEarned, payment);
        // Carbon saved = actual * carbonIntensity / 1000 (kg CO2)
        euint64 carbonSaved = FHE.div(FHE.mul(actual, ev.carbonIntensity), 1000);
        _totalCarbonSaved = FHE.add(_totalCarbonSaved, carbonSaved);
        _totalDRPayments = FHE.add(_totalDRPayments, payment);
        // Improve reliability score
        participants[bid.participant].reliabilityScore = FHE.add(participants[bid.participant].reliabilityScore, FHE.asEuint64(10));
        FHE.allowThis(bid.actualReductionKwh);
        FHE.allowThis(bid.paymentUSD);
        FHE.allow(bid.paymentUSD, bid.participant);
        FHE.allowThis(participants[bid.participant].totalEarned);
        FHE.allow(participants[bid.participant].totalEarned, bid.participant);
        FHE.allowThis(participants[bid.participant].reliabilityScore);
        FHE.allowThis(_totalCarbonSaved);
        FHE.allowThis(_totalDRPayments);
        emit ReductionVerified(eventId, bidIdx);
    }

    function settleEvent(uint256 eventId) external {
        require(isGridOperator[msg.sender], "Not operator");
        require(block.timestamp >= events[eventId].eventEnd, "Not ended");
        events[eventId].settled = true;
        emit EventSettled(eventId);
    }
}
