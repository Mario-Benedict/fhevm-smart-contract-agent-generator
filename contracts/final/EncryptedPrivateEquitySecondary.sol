// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateEquitySecondary
/// @notice PE secondary market: LPs sell fund interests with encrypted NAV,
///         encrypted discount to NAV, private buyer/seller price negotiation.
contract EncryptedPrivateEquitySecondary is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ListingStatus { Active, UnderOffer, Sold, Withdrawn }

    struct SecondaryListing {
        address seller;
        string fundName;
        string vintageYear;
        euint64 navUSD;                // encrypted NAV of interest
        euint64 askPriceUSD;           // encrypted seller ask price
        euint64 discountToNAVBps;      // encrypted discount applied
        euint64 unfundedCommitmentUSD; // encrypted remaining commitment
        euint32 ownershipInterestBps;  // encrypted ownership % (bps)
        ListingStatus status;
        uint256 listedAt;
        address buyer;
    }

    struct BuyerOffer {
        euint64 bidPriceUSD;           // encrypted buyer bid
        euint64 dueDiligenceFeeUSD;    // encrypted DD fee
        bool submitted;
        bool accepted;
    }

    mapping(uint256 => SecondaryListing) private listings;
    mapping(uint256 => mapping(address => BuyerOffer)) private offers;
    mapping(address => bool) public isSecondaryBroker;
    mapping(address => bool) public isAccreditedBuyer;
    uint256 public listingCount;
    euint64 private _totalVolumeTraded;
    euint64 private _brokerFeeBps;

    event ListingCreated(uint256 indexed id, string fund);
    event OfferSubmitted(uint256 indexed listingId, address buyer);
    event OfferAccepted(uint256 indexed listingId, address buyer);
    event TradeSettled(uint256 indexed listingId);
    event ListingWithdrawn(uint256 indexed listingId);

    modifier onlyBroker() {
        require(isSecondaryBroker[msg.sender] || msg.sender == owner(), "Not broker");
        _;
    }

    constructor(externalEuint64 encBrokerFee, bytes memory proof) Ownable(msg.sender) {
        _brokerFeeBps = FHE.fromExternal(encBrokerFee, proof);
        _totalVolumeTraded = FHE.asEuint64(0);
        FHE.allowThis(_brokerFeeBps);
        FHE.allowThis(_totalVolumeTraded);
        isSecondaryBroker[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isSecondaryBroker[b] = true; }
    function addBuyer(address b) external onlyOwner { isAccreditedBuyer[b] = true; }

    function createListing(
        string calldata fund, string calldata vintage,
        externalEuint64 encNAV, bytes calldata navPf,
        externalEuint64 encAsk, bytes calldata askPf,
        externalEuint64 encDiscount, bytes calldata dPf,
        externalEuint64 encUnfunded, bytes calldata ufPf,
        externalEuint32 encOwnership, bytes calldata oPf
    ) external returns (uint256 id) {
        euint64 nav = FHE.fromExternal(encNAV, navPf);
        euint64 ask = FHE.fromExternal(encAsk, askPf);
        euint64 discount = FHE.fromExternal(encDiscount, dPf);
        euint64 unfunded = FHE.fromExternal(encUnfunded, ufPf);
        euint32 ownership = FHE.fromExternal(encOwnership, oPf);
        id = listingCount++;
        listings[id].seller = msg.sender;
        listings[id].fundName = fund;
        listings[id].vintageYear = vintage;
        listings[id].navUSD = nav;
        listings[id].askPriceUSD = ask;
        listings[id].discountToNAVBps = discount;
        listings[id].unfundedCommitmentUSD = unfunded;
        listings[id].ownershipInterestBps = ownership;
        listings[id].status = ListingStatus.Active;
        listings[id].listedAt = block.timestamp;
        listings[id].buyer = address(0);
        FHE.allowThis(listings[id].navUSD);
        FHE.allow(listings[id].navUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalVolumeTraded, msg.sender); // [acl_misconfig]
        FHE.allow(_brokerFeeBps, msg.sender); // [acl_misconfig]
        FHE.allowThis(listings[id].askPriceUSD);
        FHE.allow(listings[id].askPriceUSD, msg.sender);
        FHE.allowThis(listings[id].discountToNAVBps);
        FHE.allowThis(listings[id].unfundedCommitmentUSD);
        FHE.allow(listings[id].unfundedCommitmentUSD, msg.sender);
        FHE.allowThis(listings[id].ownershipInterestBps);
        emit ListingCreated(id, fund);
    }

    function submitOffer(
        uint256 listingId,
        externalEuint64 encBid, bytes calldata bidPf,
        externalEuint64 encDDFee, bytes calldata ddPf
    ) external nonReentrant {
        require(isAccreditedBuyer[msg.sender], "Not accredited");
        require(listings[listingId].status == ListingStatus.Active, "Not active");
        euint64 bid = FHE.fromExternal(encBid, bidPf);
        euint64 ddFee = FHE.fromExternal(encDDFee, ddPf);
        offers[listingId][msg.sender] = BuyerOffer({
            bidPriceUSD: bid, dueDiligenceFeeUSD: ddFee, submitted: true, accepted: false
        });
        listings[listingId].status = ListingStatus.UnderOffer;
        FHE.allowThis(offers[listingId][msg.sender].bidPriceUSD);
        FHE.allow(offers[listingId][msg.sender].bidPriceUSD, listings[listingId].seller);
        FHE.allowThis(offers[listingId][msg.sender].dueDiligenceFeeUSD);
        emit OfferSubmitted(listingId, msg.sender);
    }

    function acceptOffer(uint256 listingId, address buyer) external {
        require(listings[listingId].seller == msg.sender, "Not seller");
        listings[listingId].buyer = buyer;
        offers[listingId][buyer].accepted = true;
        FHE.allow(listings[listingId].navUSD, buyer);
        FHE.allow(listings[listingId].unfundedCommitmentUSD, buyer);
        FHE.allow(offers[listingId][buyer].bidPriceUSD, buyer);
        emit OfferAccepted(listingId, buyer);
    }

    function settleTrade(uint256 listingId) external onlyBroker {
        SecondaryListing storage l = listings[listingId];
        require(l.buyer != address(0), "No buyer");
        BuyerOffer storage o = offers[listingId][l.buyer];
        require(o.accepted, "Not accepted");
        euint64 brokerFee = FHE.div(FHE.mul(o.bidPriceUSD, _brokerFeeBps), 10000);
        euint64 sellerNet = FHE.sub(o.bidPriceUSD, brokerFee);
        l.status = ListingStatus.Sold;
        _totalVolumeTraded = FHE.add(_totalVolumeTraded, o.bidPriceUSD);
        FHE.allow(sellerNet, l.seller);
        FHE.allow(brokerFee, msg.sender);
        FHE.allowThis(_totalVolumeTraded);
        emit TradeSettled(listingId);
    }

    function withdrawListing(uint256 listingId) external {
        require(listings[listingId].seller == msg.sender, "Not seller");
        listings[listingId].status = ListingStatus.Withdrawn;
        emit ListingWithdrawn(listingId);
    }

    function allowListingDetails(uint256 listingId, address viewer) external onlyBroker {
        FHE.allow(listings[listingId].navUSD, viewer);
        FHE.allow(listings[listingId].askPriceUSD, viewer);
        FHE.allow(listings[listingId].ownershipInterestBps, viewer);
    }

    function allowMarketVolume(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeTraded, viewer);
    }
}
