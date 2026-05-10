// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionWaterRights
/// @notice Water rights auction where agricultural/industrial users bid for
///         encrypted allocation volumes. State water authority manages encrypted
///         total available allocation and environmental minimum flow requirements.
contract AuctionWaterRights is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct WaterAllocation {
        string watershed;
        euint32 totalAcreFeet;        // encrypted total available
        euint32 minEnvFlowAcreFeet;   // encrypted environmental reserve
        euint64 reservePricePerAF;    // encrypted price per acre-foot
        uint256 auctionEnd;
        bool finalized;
        euint32 allocatedAcreFeet;
    }

    struct WaterBid {
        euint32 requestedAcreFeet;
        euint64 bidPricePerAF;
        euint8 waterUseEfficiency; // encrypted efficiency score (0-100)
        bool placed;
        bool allocated;
    }

    mapping(uint256 => WaterAllocation) private allocations;
    uint256 public allocationCount;
    mapping(uint256 => mapping(address => WaterBid)) private bids;
    mapping(uint256 => address[]) private bidders;
    mapping(address => bool) public isRegisteredUser;
    euint8 private _minEfficiencyScore;

    event AllocationCreated(uint256 indexed id, string watershed);
    event BidPlaced(uint256 indexed id, address indexed user);
    event RightsAllocated(uint256 indexed id);

    constructor(externalEuint8 encMinEff, bytes memory proof) Ownable(msg.sender) {
        _minEfficiencyScore = FHE.fromExternal(encMinEff, proof);
        FHE.allowThis(_minEfficiencyScore);
    }

    function registerUser(address u) external onlyOwner { isRegisteredUser[u] = true; }

    function createAllocation(
        string calldata watershed,
        externalEuint32 encTotal, bytes calldata tProof,
        externalEuint32 encEnvFlow, bytes calldata eProof,
        externalEuint64 encReserve, bytes calldata rProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = allocationCount++;
        WaterAllocation storage a = allocations[id];
        a.watershed = watershed;
        a.totalAcreFeet = FHE.fromExternal(encTotal, tProof);
        a.minEnvFlowAcreFeet = FHE.fromExternal(encEnvFlow, eProof);
        a.reservePricePerAF = FHE.fromExternal(encReserve, rProof);
        a.auctionEnd = block.timestamp + auctionDays * 1 days;
        a.allocatedAcreFeet = FHE.asEuint32(0);
        FHE.allowThis(a.totalAcreFeet);
        FHE.allowThis(a.minEnvFlowAcreFeet);
        FHE.allowThis(a.reservePricePerAF);
        FHE.allowThis(a.allocatedAcreFeet);
        emit AllocationCreated(id, watershed);
    }

    function placeBid(
        uint256 allocId,
        externalEuint32 encAF, bytes calldata aProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint8 encEff, bytes calldata eProof
    ) external nonReentrant {
        require(isRegisteredUser[msg.sender], "Not registered");
        WaterAllocation storage a = allocations[allocId];
        require(block.timestamp < a.auctionEnd, "Closed");
        require(!bids[allocId][msg.sender].placed, "Already bid");
        bids[allocId][msg.sender] = WaterBid({
            requestedAcreFeet: FHE.fromExternal(encAF, aProof),
            bidPricePerAF: FHE.fromExternal(encPrice, pProof),
            waterUseEfficiency: FHE.fromExternal(encEff, eProof),
            placed: true, allocated: false
        });
        FHE.allowThis(bids[allocId][msg.sender].requestedAcreFeet);
        FHE.allowThis(bids[allocId][msg.sender].bidPricePerAF);
        FHE.allowThis(bids[allocId][msg.sender].waterUseEfficiency);
        bidders[allocId].push(msg.sender);
        emit BidPlaced(allocId, msg.sender);
    }

    function processAllocation(uint256 allocId) external onlyOwner nonReentrant {
        WaterAllocation storage a = allocations[allocId];
        require(block.timestamp >= a.auctionEnd && !a.finalized, "Cannot process");
        a.finalized = true;
        // Available = total - envFlow
        ebool _safeSub7 = FHE.ge(a.totalAcreFeet, a.minEnvFlowAcreFeet);
        euint32 available = FHE.select(_safeSub7, FHE.sub(a.totalAcreFeet, a.minEnvFlowAcreFeet), FHE.asEuint32(0));
        address[] storage bs = bidders[allocId];
        for (uint256 i = 0; i < bs.length; i++) {
            WaterBid storage b = bids[allocId][bs[i]];
            ebool effOk = FHE.ge(b.waterUseEfficiency, _minEfficiencyScore);
            ebool priceOk = FHE.ge(b.bidPricePerAF, a.reservePricePerAF);
            ebool valid = FHE.and(effOk, priceOk);
            ebool hasCapacity = FHE.ge(available, b.requestedAcreFeet);
            ebool accept = FHE.and(valid, hasCapacity);
            euint32 granted = FHE.select(accept, b.requestedAcreFeet, FHE.asEuint32(0));
            ebool _safeSub8 = FHE.ge(available, granted);
            available = FHE.select(_safeSub8, FHE.sub(available, granted), FHE.asEuint64(0));
            a.allocatedAcreFeet = FHE.add(a.allocatedAcreFeet, granted);
            b.allocated = FHE.isInitialized(accept);
            FHE.allowThis(available);
            FHE.allowThis(a.allocatedAcreFeet);
            FHE.allow(granted, bs[i]);
        }
        emit RightsAllocated(allocId);
    }
}
