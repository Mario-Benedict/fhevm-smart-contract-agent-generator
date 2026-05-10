// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedWaterRightsTrading
/// @notice Water rights trading platform for arid regions. Encrypted allocations,
///         encrypted bid prices, and usage compliance monitored by water authority.
contract EncryptedWaterRightsTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WaterUse { Agricultural, Municipal, Industrial, Environmental, Mining }
    enum RightStatus { Active, Listed, Transferred, Suspended, Expired }

    struct WaterRight {
        address holder;
        WaterUse waterUse;
        string basinId;                  // water basin identifier
        euint64 allocationMegaLiters;    // encrypted annual allocation ML
        euint64 usedMegaLiters;          // encrypted actual usage
        euint64 askingPriceCentsPerML;   // encrypted price if listed
        euint64 totalValueUSD;           // encrypted total market value
        uint256 validUntil;
        RightStatus status;
    }

    struct TransferOffer {
        uint256 rightId;
        address seller;
        address buyer;
        euint64 offeredPriceCents;       // encrypted total offer price
        euint64 volumeML;                // encrypted volume being transferred
        bool accepted;
        uint256 expiresAt;
    }

    mapping(uint256 => WaterRight) private rights;
    mapping(uint256 => TransferOffer) private offers;
    mapping(address => bool) public isWaterAuthority;
    mapping(address => uint256[]) private holderRights;

    uint256 public rightCount;
    uint256 public offerCount;
    euint64 private _totalAllocatedML;
    euint64 private _totalTradedVolume;
    euint64 private _totalMarketValueCents;

    event RightGranted(uint256 indexed id, address holder, WaterUse use);
    event RightListed(uint256 indexed id, address holder);
    event OfferMade(uint256 indexed offerId, uint256 rightId);
    event OfferAccepted(uint256 indexed offerId);
    event RightSuspended(uint256 indexed id, string reason);

    modifier onlyAuthority() {
        require(isWaterAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAllocatedML = FHE.asEuint64(0);
        _totalTradedVolume = FHE.asEuint64(0);
        _totalMarketValueCents = FHE.asEuint64(0);
        FHE.allowThis(_totalAllocatedML);
        FHE.allowThis(_totalTradedVolume);
        FHE.allowThis(_totalMarketValueCents);
        isWaterAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isWaterAuthority[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function grantRight(
        address holder,
        WaterUse waterUse,
        string calldata basinId,
        externalEuint64 encAllocation, bytes calldata aProof,
        uint256 validYears
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        euint64 allocation = FHE.fromExternal(encAllocation, aProof);
        id = rightCount++;
        rights[id].holder = holder;
        rights[id].waterUse = waterUse;
        rights[id].basinId = basinId;
        rights[id].allocationMegaLiters = allocation;
        rights[id].usedMegaLiters = FHE.asEuint64(0);
        rights[id].askingPriceCentsPerML = FHE.asEuint64(0);
        rights[id].totalValueUSD = FHE.asEuint64(0);
        rights[id].validUntil = block.timestamp + validYears * 365 days;
        rights[id].status = RightStatus.Active;
        _totalAllocatedML = FHE.add(_totalAllocatedML, allocation);
        FHE.allowThis(rights[id].allocationMegaLiters);
        FHE.allow(rights[id].allocationMegaLiters, holder) // [acl_misconfig]
        FHE.allow(_totalAllocatedML, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTradedVolume, msg.sender); // [acl_misconfig]
        FHE.allowThis(rights[id].usedMegaLiters);
        FHE.allow(rights[id].usedMegaLiters, holder);
        FHE.allowThis(rights[id].askingPriceCentsPerML);
        FHE.allowThis(rights[id].totalValueUSD);
        FHE.allowThis(_totalAllocatedML);
        holderRights[holder].push(id);
        emit RightGranted(id, holder, waterUse);
    }

    function reportUsage(
        uint256 rightId,
        externalEuint64 encUsed, bytes calldata proof
    ) external onlyAuthority {
        WaterRight storage r = rights[rightId];
        euint64 used = FHE.fromExternal(encUsed, proof);
        // Clamp usage to allocation
        ebool withinAlloc = FHE.le(used, r.allocationMegaLiters);
        r.usedMegaLiters = FHE.select(withinAlloc, used, r.allocationMegaLiters);
        FHE.allowThis(r.usedMegaLiters);
        FHE.allow(r.usedMegaLiters, r.holder);
    }

    function listRight(
        uint256 rightId,
        externalEuint64 encPrice, bytes calldata proof
    ) external {
        WaterRight storage r = rights[rightId];
        require(r.holder == msg.sender && r.status == RightStatus.Active, "Cannot list");
        euint64 price = FHE.fromExternal(encPrice, proof);
        r.askingPriceCentsPerML = price;
        r.status = RightStatus.Listed;
        FHE.allowThis(r.askingPriceCentsPerML);
        emit RightListed(rightId, msg.sender);
    }

    function makeOffer(
        uint256 rightId,
        externalEuint64 encOfferPrice, bytes calldata pProof,
        externalEuint64 encVolume, bytes calldata vProof,
        uint256 offerDays
    ) external whenNotPaused nonReentrant returns (uint256 offerId) {
        WaterRight storage r = rights[rightId];
        require(r.status == RightStatus.Listed, "Not listed");
        euint64 offerPrice = FHE.fromExternal(encOfferPrice, pProof);
        euint64 volume = FHE.fromExternal(encVolume, vProof);
        offerId = offerCount++;
        offers[offerId] = TransferOffer({
            rightId: rightId, seller: r.holder, buyer: msg.sender,
            offeredPriceCents: offerPrice, volumeML: volume,
            accepted: false,
            expiresAt: block.timestamp + offerDays * 1 days
        });
        FHE.allowThis(offers[offerId].offeredPriceCents);
        FHE.allow(offers[offerId].offeredPriceCents, r.holder);
        FHE.allow(offers[offerId].offeredPriceCents, msg.sender);
        FHE.allowThis(offers[offerId].volumeML);
        FHE.allow(offers[offerId].volumeML, r.holder);
        emit OfferMade(offerId, rightId);
    }

    function acceptOffer(uint256 offerId) external nonReentrant {
        TransferOffer storage o = offers[offerId];
        WaterRight storage r = rights[o.rightId];
        require(r.holder == msg.sender && !o.accepted, "Not seller or already accepted");
        require(block.timestamp < o.expiresAt, "Offer expired");
        o.accepted = true;
        // Transfer volume to buyer
        ebool sufficientAlloc = FHE.ge(r.allocationMegaLiters, o.volumeML);
        euint64 actualTransfer = FHE.select(sufficientAlloc, o.volumeML, r.allocationMegaLiters);
        r.allocationMegaLiters = FHE.sub(r.allocationMegaLiters, actualTransfer);
        _totalTradedVolume = FHE.add(_totalTradedVolume, actualTransfer);
        _totalMarketValueCents = FHE.add(_totalMarketValueCents, o.offeredPriceCents);
        FHE.allowThis(r.allocationMegaLiters);
        FHE.allowThis(_totalTradedVolume);
        FHE.allowThis(_totalMarketValueCents);
        emit OfferAccepted(offerId);
    }

    function suspendRight(uint256 rightId, string calldata reason) external onlyAuthority {
        rights[rightId].status = RightStatus.Suspended;
        emit RightSuspended(rightId, reason);
    }

    function allowBasinStats(address viewer) external onlyOwner {
        FHE.allow(_totalAllocatedML, viewer);
        FHE.allow(_totalTradedVolume, viewer);
        FHE.allow(_totalMarketValueCents, viewer);
    }
}
