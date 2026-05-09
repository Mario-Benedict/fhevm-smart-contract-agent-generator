// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title HealthDataMarketplace
/// @notice Patients tokenize encrypted health data records. Pharma companies
///         bid privately for dataset access rights using encrypted offers.
contract HealthDataMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DataListing {
        address patient;
        string dataCategory;        // e.g. "genomic", "imaging", "lab"
        euint64 minAcceptablePrice;
        euint64 highestBid;
        address highestBidder;
        uint256 deadline;
        bool sold;
    }

    struct AccessRight {
        address buyer;
        uint256 listingId;
        uint256 accessExpiry;
        bool active;
    }

    mapping(uint256 => DataListing) private listings;
    mapping(uint256 => AccessRight) private accessRights;
    mapping(address => euint64) private _earnings;
    mapping(address => mapping(uint256 => euint64)) private _bids;
    uint256 public nextListingId;
    uint256 public platformFeeBps;
    euint64 private _platformRevenue;

    event Listed(uint256 indexed id, address patient);
    event BidPlaced(uint256 indexed id, address bidder);
    event Sold(uint256 indexed id, address buyer);

    constructor(uint256 _feeBps) Ownable(msg.sender) {
        platformFeeBps = _feeBps;
        _platformRevenue = FHE.asEuint64(0);
        FHE.allowThis(_platformRevenue);
    }

    function listData(
        string calldata category,
        externalEuint64 encMinPrice, bytes calldata proof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 minPrice = FHE.fromExternal(encMinPrice, proof);
        id = nextListingId++;
        listings[id] = DataListing({
            patient: msg.sender,
            dataCategory: category,
            minAcceptablePrice: minPrice,
            highestBid: FHE.asEuint64(0),
            highestBidder: address(0),
            deadline: block.timestamp + durationDays * 1 days,
            sold: false
        });
        FHE.allowThis(listings[id].minAcceptablePrice);
        FHE.allowThis(listings[id].highestBid);
        emit Listed(id, msg.sender);
    }

    function placeBid(uint256 listingId, externalEuint64 encBid, bytes calldata proof)
        external nonReentrant
    {
        DataListing storage l = listings[listingId];
        require(!l.sold && block.timestamp < l.deadline, "Listing invalid");
        euint64 bid = FHE.fromExternal(encBid, proof);
        ebool isHigher = FHE.gt(bid, l.highestBid);
        l.highestBid = FHE.select(isHigher, bid, l.highestBid);
        if (FHE.isInitialized(isHigher)) l.highestBidder = msg.sender;
        _bids[msg.sender][listingId] = bid;
        FHE.allowThis(l.highestBid);
        FHE.allowThis(_bids[msg.sender][listingId]);
        emit BidPlaced(listingId, msg.sender);
    }

    function finalizeAuction(uint256 listingId) external nonReentrant {
        DataListing storage l = listings[listingId];
        require(block.timestamp >= l.deadline && !l.sold, "Not ready");
        ebool meetsMin = FHE.ge(l.highestBid, l.minAcceptablePrice);
        l.sold = FHE.isInitialized(meetsMin);
        if (l.sold && l.highestBidder != address(0)) {
            euint64 fee = FHE.div(FHE.mul(l.highestBid, FHE.asEuint64(uint64(platformFeeBps))), 10000);
            euint64 net = FHE.sub(l.highestBid, fee);
            _earnings[l.patient] = FHE.add(_earnings[l.patient], net);
            _platformRevenue = FHE.add(_platformRevenue, fee);
            uint256 accessId = nextListingId++;
            accessRights[accessId] = AccessRight({
                buyer: l.highestBidder,
                listingId: listingId,
                accessExpiry: block.timestamp + 365 days,
                active: true
            });
            FHE.allowThis(_earnings[l.patient]);
            FHE.allow(_earnings[l.patient], l.patient);
            FHE.allowThis(_platformRevenue);
            emit Sold(listingId, l.highestBidder);
        }
    }

    function withdrawEarnings() external nonReentrant {
        euint64 amount = _earnings[msg.sender];
        _earnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_earnings[msg.sender]);
        FHE.allow(amount, msg.sender);
    }

    function allowEarnings(address viewer) external { FHE.allow(_earnings[msg.sender], viewer); }
    function allowPlatformRevenue(address viewer) external onlyOwner { FHE.allow(_platformRevenue, viewer); }
}
