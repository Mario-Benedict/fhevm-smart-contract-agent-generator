// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateRailFreightCapacityBidding
/// @notice Encrypted rail network capacity slot bidding: confidential freight volumes,
///         hidden revenue tonne-kilometers, private priority scoring for hazardous goods,
///         and encrypted infrastructure access charges.
contract PrivateRailFreightCapacityBidding is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CargoClass { GeneralFreight, BulkGoods, ContainerUnit, HazardousChemical, Refrigerated, BreakBulk }
    enum SlotStatus { Available, Awarded, Cancelled, Completed }

    struct TrainPathSlot {
        string pathCode;
        string originTerminal;
        string destinationTerminal;
        uint256 scheduledDeparture;
        euint32 capacityTonnes;        // encrypted max payload
        euint64 reservePricePerTonneKm;// encrypted reserve charge rate
        euint64 awardedPriceUSD;       // encrypted winning price
        address awardedBidder;
        SlotStatus status;
    }

    struct FreightBid {
        uint256 slotId;
        address freightOperator;
        CargoClass cargoClass;
        euint32 requestedTonnes;       // encrypted cargo weight
        euint64 bidAmountUSD;          // encrypted bid
        euint8  hazardClassFlag;       // encrypted hazard classification
        euint64 revenueEstimateUSD;    // encrypted operator revenue estimate
        bool accepted;
    }

    mapping(uint256 => TrainPathSlot) private pathSlots;
    mapping(uint256 => FreightBid) private bids;
    mapping(uint256 => uint256[]) private slotBidIds;
    mapping(address => bool) public isRailAuthority;

    uint256 public slotCount;
    uint256 public bidCount;
    euint64 private _totalAwardedRevenueUSD;
    euint64 private _totalCapacityOfferedTonnes;

    event SlotCreated(uint256 indexed id, string pathCode, uint256 departure);
    event BidSubmitted(uint256 indexed bidId, uint256 slotId);
    event SlotAwarded(uint256 indexed slotId, address winner);

    modifier onlyRailAuthority() {
        require(isRailAuthority[msg.sender] || msg.sender == owner(), "Not rail authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAwardedRevenueUSD = FHE.asEuint64(0);
        _totalCapacityOfferedTonnes = FHE.asEuint64(0);
        FHE.allowThis(_totalAwardedRevenueUSD);
        FHE.allowThis(_totalCapacityOfferedTonnes);
        isRailAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addRailAuthority(address a) external onlyOwner { isRailAuthority[a] = true; }

    function createPathSlot(
        string calldata pathCode,
        string calldata origin,
        string calldata destination,
        uint256 scheduledDeparture,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint64 encReserveRate, bytes calldata rrProof
    ) external onlyRailAuthority whenNotPaused returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, capProof);
        euint64 reserveRate = FHE.fromExternal(encReserveRate, rrProof);
        id = slotCount++;
        pathSlots[id] = TrainPathSlot({
            pathCode: pathCode, originTerminal: origin, destinationTerminal: destination,
            scheduledDeparture: scheduledDeparture, capacityTonnes: cap,
            reservePricePerTonneKm: reserveRate, awardedPriceUSD: FHE.asEuint64(0),
            awardedBidder: address(0), status: SlotStatus.Available
        });
        _totalCapacityOfferedTonnes = FHE.add(_totalCapacityOfferedTonnes, FHE.asEuint64(uint64(1)));
        FHE.allowThis(pathSlots[id].capacityTonnes);
        FHE.allowThis(pathSlots[id].reservePricePerTonneKm);
        FHE.allowThis(pathSlots[id].awardedPriceUSD);
        FHE.allowThis(_totalCapacityOfferedTonnes);
        emit SlotCreated(id, pathCode, scheduledDeparture);
    }

    function submitBid(
        uint256 slotId,
        CargoClass cargoClass,
        externalEuint32 encTonnes, bytes calldata tProof,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint8 encHazard, bytes calldata hProof,
        externalEuint64 encRevEst, bytes calldata reProof
    ) external whenNotPaused returns (uint256 bidId) {
        require(pathSlots[slotId].status == SlotStatus.Available, "Slot not available");
        euint32 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint8 hazard = FHE.fromExternal(encHazard, hProof);
        euint64 revEst = FHE.fromExternal(encRevEst, reProof);
        bidId = bidCount++;
        bids[bidId] = FreightBid({
            slotId: slotId, freightOperator: msg.sender, cargoClass: cargoClass,
            requestedTonnes: tonnes, bidAmountUSD: bid, hazardClassFlag: hazard,
            revenueEstimateUSD: revEst, accepted: false
        });
        slotBidIds[slotId].push(bidId);
        FHE.allowThis(bids[bidId].requestedTonnes); FHE.allow(bids[bidId].requestedTonnes, msg.sender);
        FHE.allowThis(bids[bidId].bidAmountUSD); FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].hazardClassFlag);
        FHE.allowThis(bids[bidId].revenueEstimateUSD); FHE.allow(bids[bidId].revenueEstimateUSD, msg.sender);
        emit BidSubmitted(bidId, slotId);
    }

    function awardSlot(uint256 slotId, uint256 winningBidId) external onlyRailAuthority nonReentrant {
        TrainPathSlot storage slot_ = pathSlots[slotId];
        require(slot_.status == SlotStatus.Available, "Not available");
        FreightBid storage wb = bids[winningBidId];
        require(wb.slotId == slotId, "Bid/slot mismatch");
        slot_.awardedPriceUSD = wb.bidAmountUSD;
        slot_.awardedBidder = wb.freightOperator;
        slot_.status = SlotStatus.Awarded;
        wb.accepted = true;
        _totalAwardedRevenueUSD = FHE.add(_totalAwardedRevenueUSD, wb.bidAmountUSD);
        FHE.allowThis(slot_.awardedPriceUSD); FHE.allow(slot_.awardedPriceUSD, wb.freightOperator);
        FHE.allowThis(_totalAwardedRevenueUSD);
        emit SlotAwarded(slotId, wb.freightOperator);
    }

    function allowRevenueView(address viewer) external onlyOwner {
        FHE.allow(_totalAwardedRevenueUSD, viewer);
        FHE.allow(_totalCapacityOfferedTonnes, viewer);
    }
}
