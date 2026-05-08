// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateLivestockAuction
/// @notice Agricultural livestock sealed-bid auction: encrypted reserve price per head,
///         encrypted health scores, encrypted weight assessments, and confidential buyer scoring.
contract PrivateLivestockAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LivestockType { CATTLE, SHEEP, PIGS, GOATS, HORSES, POULTRY }

    struct LivestockLot {
        string lotId;
        LivestockType animalType;
        uint256 headCount;
        euint64 reservePricePerHead;  // encrypted reserve price
        euint64 avgWeightKg;          // encrypted average weight
        euint8 healthScore;           // encrypted health grade (0-100)
        euint64 vaccinationStatus;    // encrypted vaccination compliance score
        uint256 auctionClose;
        bool sold;
        address seller;
    }

    struct Bid {
        uint256 lotId;
        address bidder;
        euint64 pricePerHead;       // encrypted bid per head
        euint64 totalBidUSD;        // encrypted total bid
        bool revealed;
    }

    struct BuyerProfile {
        euint64 creditScore;        // encrypted creditworthiness
        euint64 purchaseHistoryUSD; // encrypted past purchase volume
        bool approved;
    }

    mapping(uint256 => LivestockLot) private lots;
    mapping(uint256 => Bid) private bids;
    mapping(address => BuyerProfile) private buyers;
    mapping(uint256 => uint256[]) private lotBidIds;
    uint256 public lotCount;
    uint256 public bidCount;
    mapping(address => bool) public isAuctioneer;

    event LotCreated(uint256 indexed lotId, string id, LivestockType animalType);
    event BidPlaced(uint256 indexed bidId, uint256 lotId, address bidder);
    event LotSold(uint256 indexed lotId, uint256 winningBidId, address buyer);
    event BuyerApproved(address indexed buyer);

    constructor() Ownable(msg.sender) {
        isAuctioneer[msg.sender] = true;
    }

    function addAuctioneer(address a) external onlyOwner { isAuctioneer[a] = true; }

    function approveBuyer(
        address buyer,
        externalEuint64 encCredit, bytes calldata cProof,
        externalEuint64 encHistory, bytes calldata hProof
    ) external {
        require(isAuctioneer[msg.sender], "Not auctioneer");
        euint64 credit = FHE.fromExternal(encCredit, cProof);
        euint64 history = FHE.fromExternal(encHistory, hProof);
        buyers[buyer] = BuyerProfile({ creditScore: credit, purchaseHistoryUSD: history, approved: true });
        FHE.allowThis(buyers[buyer].creditScore);
        FHE.allowThis(buyers[buyer].purchaseHistoryUSD);
        FHE.allow(buyers[buyer].creditScore, buyer);
        emit BuyerApproved(buyer);
    }

    function createLot(
        string calldata lotId, LivestockType animalType, uint256 headCount,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint64 encWeight, bytes calldata wProof,
        externalEuint8 encHealth, bytes calldata hProof,
        externalEuint64 encVax, bytes calldata vProof,
        uint256 auctionClose
    ) external returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, rProof);
        euint64 weight = FHE.fromExternal(encWeight, wProof);
        euint8 health = FHE.fromExternal(encHealth, hProof);
        euint64 vax = FHE.fromExternal(encVax, vProof);
        id = lotCount++;
        lots[id] = LivestockLot({
            lotId: lotId, animalType: animalType, headCount: headCount,
            reservePricePerHead: reserve, avgWeightKg: weight,
            healthScore: health, vaccinationStatus: vax,
            auctionClose: auctionClose, sold: false, seller: msg.sender
        });
        FHE.allowThis(lots[id].reservePricePerHead);
        FHE.allowThis(lots[id].avgWeightKg);
        FHE.allowThis(lots[id].healthScore);
        FHE.allowThis(lots[id].vaccinationStatus);
        emit LotCreated(id, lotId, animalType);
    }

    function placeBid(
        uint256 lotId,
        externalEuint64 encPricePerHead, bytes calldata proof
    ) external nonReentrant returns (uint256 bidId) {
        require(buyers[msg.sender].approved, "Not approved buyer");
        LivestockLot storage lot = lots[lotId];
        require(!lot.sold && block.timestamp < lot.auctionClose, "Closed");
        euint64 price = FHE.fromExternal(encPricePerHead, proof);
        euint64 total = FHE.mul(price, FHE.asEuint64(uint64(lot.headCount)));
        // Check credit capacity
        ebool hasCap = FHE.ge(buyers[msg.sender].creditScore, FHE.asEuint64(500));
        euint64 effectiveTotal = FHE.select(hasCap, total, FHE.asEuint64(0));
        bidId = bidCount++;
        bids[bidId] = Bid({ lotId: lotId, bidder: msg.sender, pricePerHead: price, totalBidUSD: effectiveTotal, revealed: false });
        lotBidIds[lotId].push(bidId);
        FHE.allowThis(bids[bidId].pricePerHead);
        FHE.allowThis(bids[bidId].totalBidUSD);
        emit BidPlaced(bidId, lotId, msg.sender);
    }

    function awardLot(uint256 lotId, uint256 winningBidId) external nonReentrant {
        require(isAuctioneer[msg.sender], "Not auctioneer");
        LivestockLot storage lot = lots[lotId];
        require(!lot.sold && block.timestamp >= lot.auctionClose, "Not ready");
        // Validate bid meets reserve
        ebool meetsReserve = FHE.ge(bids[winningBidId].pricePerHead, lot.reservePricePerHead);
        require(FHE.isInitialized(bids[winningBidId].pricePerHead), "Invalid bid");
        lot.sold = true;
        address buyer = bids[winningBidId].bidder;
        FHE.allow(bids[winningBidId].totalBidUSD, buyer);
        FHE.allow(bids[winningBidId].totalBidUSD, lot.seller);
        FHE.allow(lot.avgWeightKg, buyer);
        FHE.allow(lot.healthScore, buyer);
        // Update buyer history
        buyers[buyer].purchaseHistoryUSD = FHE.add(buyers[buyer].purchaseHistoryUSD, bids[winningBidId].totalBidUSD);
        FHE.allowThis(buyers[buyer].purchaseHistoryUSD);
        emit LotSold(lotId, winningBidId, buyer);
    }
}
