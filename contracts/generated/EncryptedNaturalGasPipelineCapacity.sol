// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedNaturalGasPipelineCapacity
/// @notice Gas pipeline operators auction encrypted capacity slots to shippers.
///         Bids, contracted volumes, and tariff rates remain confidential.
contract EncryptedNaturalGasPipelineCapacity is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum SlotStatus { Available, Bidding, Awarded, Active, Terminated }

    struct PipelineSlot {
        string pipelineId;
        string entryPoint;
        string exitPoint;
        euint32 capacityMMBTUperDay;   // encrypted max daily throughput
        euint64 reservationPriceUSD;   // encrypted minimum reservation fee
        euint64 awardedTariffUSD;      // encrypted final awarded tariff
        uint256 auctionEnd;
        SlotStatus status;
        address winner;
    }

    struct CapacityBid {
        uint256 slotId;
        address shipper;
        euint64 bidAmountUSD;          // encrypted bid amount
        euint32 requestedMMBTU;        // encrypted requested volume
        bool accepted;
    }

    mapping(uint256 => PipelineSlot) private slots;
    mapping(uint256 => CapacityBid) private bids;
    mapping(uint256 => uint256) private slotWinningBid;
    mapping(address => bool) public isQualifiedShipper;

    uint256 public slotCount;
    uint256 public bidCount;
    euint64 private _totalRevenueUSD;
    euint64 private _totalCapacityMMBTU;

    event SlotListed(uint256 indexed id, string pipelineId);
    event BidSubmitted(uint256 indexed bidId, uint256 slotId, address shipper);
    event SlotAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {
        _totalRevenueUSD = FHE.asEuint64(0);
        _totalCapacityMMBTU = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenueUSD);
        FHE.allowThis(_totalCapacityMMBTU);
    }

    function addShipper(address s) external onlyOwner { isQualifiedShipper[s] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function listSlot(
        string calldata pipelineId, string calldata entry, string calldata exit,
        externalEuint32 encCapacity, bytes calldata cProof,
        externalEuint64 encReserve, bytes calldata rProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        euint32 cap = FHE.fromExternal(encCapacity, cProof);
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        id = slotCount++;
        slots[id] = PipelineSlot({
            pipelineId: pipelineId, entryPoint: entry, exitPoint: exit,
            capacityMMBTUperDay: cap, reservationPriceUSD: reserve,
            awardedTariffUSD: FHE.asEuint64(0),
            auctionEnd: block.timestamp + auctionDays * 1 days,
            status: SlotStatus.Bidding, winner: address(0)
        });
        _totalCapacityMMBTU = FHE.add(_totalCapacityMMBTU, FHE.asEuint64(0));
        FHE.allowThis(slots[id].capacityMMBTUperDay);
        FHE.allowThis(slots[id].reservationPriceUSD);
        FHE.allowThis(slots[id].awardedTariffUSD);
        FHE.allowThis(_totalCapacityMMBTU);
        emit SlotListed(id, pipelineId);
    }

    function submitBid(
        uint256 slotId,
        externalEuint64 encBid, bytes calldata bProof,
        externalEuint32 encVolume, bytes calldata vProof
    ) external whenNotPaused nonReentrant returns (uint256 bidId) {
        require(isQualifiedShipper[msg.sender], "Not qualified");
        PipelineSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Bidding && block.timestamp < s.auctionEnd, "Not in bidding");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        euint32 vol = FHE.fromExternal(encVolume, vProof);
        ebool aboveReserve = FHE.ge(bid, s.reservationPriceUSD);
        euint64 validBid = FHE.select(aboveReserve, bid, FHE.asEuint64(0));
        bidId = bidCount++;
        bids[bidId] = CapacityBid({
            slotId: slotId, shipper: msg.sender,
            bidAmountUSD: validBid, requestedMMBTU: vol, accepted: false
        });
        FHE.allowThis(bids[bidId].bidAmountUSD);
        FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].requestedMMBTU);
        FHE.allow(bids[bidId].requestedMMBTU, msg.sender);
        emit BidSubmitted(bidId, slotId, msg.sender);
    }

    function awardSlot(uint256 slotId, uint256 winningBidId) external onlyOwner nonReentrant {
        PipelineSlot storage s = slots[slotId];
        require(s.status == SlotStatus.Bidding && block.timestamp >= s.auctionEnd, "Auction not ended");
        CapacityBid storage b = bids[winningBidId];
        require(b.slotId == slotId, "Wrong slot");
        b.accepted = true;
        s.awardedTariffUSD = b.bidAmountUSD;
        s.winner = b.shipper;
        s.status = SlotStatus.Awarded;
        slotWinningBid[slotId] = winningBidId;
        _totalRevenueUSD = FHE.add(_totalRevenueUSD, b.bidAmountUSD);
        FHE.allowThis(s.awardedTariffUSD);
        FHE.allow(s.awardedTariffUSD, b.shipper);
        FHE.allowThis(_totalRevenueUSD);
        emit SlotAwarded(slotId, b.shipper);
    }

    function activateSlot(uint256 slotId) external onlyOwner {
        require(slots[slotId].status == SlotStatus.Awarded, "Not awarded");
        slots[slotId].status = SlotStatus.Active;
    }

    function allowPipelineStats(address viewer) external onlyOwner {
        FHE.allow(_totalRevenueUSD, viewer);
        FHE.allow(_totalCapacityMMBTU, viewer);
    }
}
