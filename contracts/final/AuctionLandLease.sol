// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionLandLease
/// @notice Agricultural land lease auction. Encrypted annual rent bids compete
///         for multi-year leases. Lessor prioritizes bidders with highest encrypted
///         sustainable farming score alongside the highest bid.
contract AuctionLandLease is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LandParcel {
        string location;
        uint256 areaHectares;
        uint256 leaseDurationYears;
        euint64 reserveAnnualRent;  // encrypted
        euint8 minSustainScore;     // encrypted minimum farming sustainability score
        uint256 auctionEnd;
        bool finalized;
        address lessee;
        euint64 winningRent;
    }

    struct LeaseBid {
        euint64 annualRent;       // encrypted annual rent offer
        euint8 sustainScore;      // encrypted sustainability commitment score
        euint8 farmingExperience; // encrypted years of farming experience
        bool placed;
    }

    mapping(uint256 => LandParcel) private parcels;
    uint256 public parcelCount;
    mapping(uint256 => mapping(address => LeaseBid)) private bids;
    mapping(uint256 => address[]) private bidders;
    mapping(address => bool) public isRegisteredFarmer;

    event ParcelListed(uint256 indexed id, string location);
    event LeaseBidPlaced(uint256 indexed id, address farmer);
    event LeaseAwarded(uint256 indexed id, address lessee);

    constructor() Ownable(msg.sender) {}

    function registerFarmer(address f) external onlyOwner { isRegisteredFarmer[f] = true; }

    function listParcel(
        string calldata location, uint256 area, uint256 leaseDuration,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint8 encMinSustain, bytes calldata sProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = parcelCount++;
        LandParcel storage p = parcels[id];
        p.location = location;
        p.areaHectares = area;
        p.leaseDurationYears = leaseDuration;
        p.reserveAnnualRent = FHE.fromExternal(encReserve, rProof);
        p.minSustainScore = FHE.fromExternal(encMinSustain, sProof);
        p.auctionEnd = block.timestamp + auctionDays * 1 days;
        p.winningRent = FHE.asEuint64(0);
        FHE.allowThis(p.reserveAnnualRent);
        FHE.allowThis(p.minSustainScore);
        FHE.allowThis(p.winningRent);
        emit ParcelListed(id, location);
    }

    function placeBid(
        uint256 parcelId,
        externalEuint64 encRent, bytes calldata rProof,
        externalEuint8 encSustain, bytes calldata sProof,
        externalEuint8 encExp, bytes calldata eProof
    ) external nonReentrant {
        require(isRegisteredFarmer[msg.sender], "Not registered");
        LandParcel storage p = parcels[parcelId];
        require(block.timestamp < p.auctionEnd, "Closed");
        require(!bids[parcelId][msg.sender].placed, "Already bid");
        bids[parcelId][msg.sender] = LeaseBid({
            annualRent: FHE.fromExternal(encRent, rProof),
            sustainScore: FHE.fromExternal(encSustain, sProof),
            farmingExperience: FHE.fromExternal(encExp, eProof),
            placed: true
        });
        FHE.allowThis(bids[parcelId][msg.sender].annualRent);
        FHE.allowThis(bids[parcelId][msg.sender].sustainScore);
        FHE.allowThis(bids[parcelId][msg.sender].farmingExperience);
        bidders[parcelId].push(msg.sender);
        emit LeaseBidPlaced(parcelId, msg.sender);
    }

    function awardLease(uint256 parcelId) external onlyOwner nonReentrant {
        LandParcel storage p = parcels[parcelId];
        require(block.timestamp >= p.auctionEnd && !p.finalized, "Cannot award");
        p.finalized = true;
        euint64 bestRent = FHE.asEuint64(0);
        address bestBidder = address(0);
        address[] storage bs = bidders[parcelId];
        for (uint256 i = 0; i < bs.length; i++) {
            LeaseBid storage b = bids[parcelId][bs[i]];
            ebool sustainOk = FHE.ge(b.sustainScore, p.minSustainScore);
            ebool rentOk = FHE.ge(b.annualRent, p.reserveAnnualRent);
            ebool valid = FHE.and(sustainOk, rentOk);
            ebool isBest = FHE.gt(b.annualRent, bestRent);
            ebool winner = FHE.and(valid, isBest);
            bestRent = FHE.select(winner, b.annualRent, bestRent);
            if (FHE.isInitialized(winner)) bestBidder = bs[i];
        }
        p.lessee = bestBidder;
        p.winningRent = bestRent;
        FHE.allowThis(p.winningRent);
        if (bestBidder != address(0)) FHE.allow(p.winningRent, bestBidder);
        emit LeaseAwarded(parcelId, bestBidder);
    }
}
