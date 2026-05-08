// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionCarbonCredit
/// @notice Carbon credit auction where companies bid for encrypted tonne allocations.
///         Verifier attests to carbon offset quality (encrypted score). Companies with
///         higher compliance scores receive priority allocation at the same price.
contract AuctionCarbonCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CarbonPool {
        string projectName;
        string methodology; // Verra, Gold Standard, etc.
        euint32 availableTonnes;
        euint64 reservePricePerTonne;
        euint8 qualityScore;      // encrypted 0-100
        uint256 auctionEnd;
        bool finalized;
        euint32 soldTonnes;
    }

    struct CompanyBid {
        euint32 requestedTonnes;
        euint64 bidPricePerTonne;
        euint8 complianceScore;   // encrypted compliance priority score
        bool placed;
        euint32 allocatedTonnes;
    }

    mapping(uint256 => CarbonPool) private pools;
    uint256 public poolCount;
    mapping(uint256 => mapping(address => CompanyBid)) private bids;
    mapping(uint256 => address[]) private companies;
    mapping(address => bool) public isRegisteredCompany;

    event PoolCreated(uint256 indexed id, string projectName);
    event BidPlaced(uint256 indexed id, address company);
    event AllocationComplete(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function registerCompany(address c) external onlyOwner { isRegisteredCompany[c] = true; }

    function createPool(
        string calldata projectName, string calldata methodology,
        externalEuint32 encTonnes, bytes calldata tProof,
        externalEuint64 encReserve, bytes calldata rProof,
        externalEuint8 encQuality, bytes calldata qProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = poolCount++;
        pools[id].projectName = projectName;
        pools[id].methodology = methodology;
        pools[id].availableTonnes = FHE.fromExternal(encTonnes, tProof);
        pools[id].reservePricePerTonne = FHE.fromExternal(encReserve, rProof);
        pools[id].qualityScore = FHE.fromExternal(encQuality, qProof);
        pools[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        pools[id].soldTonnes = FHE.asEuint32(0);
        FHE.allowThis(pools[id].availableTonnes);
        FHE.allowThis(pools[id].reservePricePerTonne);
        FHE.allowThis(pools[id].qualityScore);
        FHE.allowThis(pools[id].soldTonnes);
        emit PoolCreated(id, projectName);
    }

    function placeBid(
        uint256 poolId,
        externalEuint32 encTonnes, bytes calldata tProof,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint8 encCompliance, bytes calldata cProof
    ) external nonReentrant {
        require(isRegisteredCompany[msg.sender], "Not registered");
        CarbonPool storage p = pools[poolId];
        require(block.timestamp < p.auctionEnd, "Closed");
        require(!bids[poolId][msg.sender].placed, "Already bid");
        bids[poolId][msg.sender] = CompanyBid({
            requestedTonnes: FHE.fromExternal(encTonnes, tProof),
            bidPricePerTonne: FHE.fromExternal(encPrice, pProof),
            complianceScore: FHE.fromExternal(encCompliance, cProof),
            placed: true, allocatedTonnes: FHE.asEuint32(0)
        });
        FHE.allowThis(bids[poolId][msg.sender].requestedTonnes);
        FHE.allowThis(bids[poolId][msg.sender].bidPricePerTonne);
        FHE.allowThis(bids[poolId][msg.sender].complianceScore);
        FHE.allowThis(bids[poolId][msg.sender].allocatedTonnes);
        companies[poolId].push(msg.sender);
        emit BidPlaced(poolId, msg.sender);
    }

    function processAllocation(uint256 poolId) external onlyOwner nonReentrant {
        CarbonPool storage p = pools[poolId];
        require(block.timestamp >= p.auctionEnd && !p.finalized, "Cannot process");
        p.finalized = true;
        euint32 remaining = p.availableTonnes;
        address[] storage cs = companies[poolId];
        for (uint256 i = 0; i < cs.length; i++) {
            CompanyBid storage b = bids[poolId][cs[i]];
            ebool priceOk = FHE.ge(b.bidPricePerTonne, p.reservePricePerTonne);
            ebool hasCapacity = FHE.ge(remaining, b.requestedTonnes);
            ebool valid = FHE.and(priceOk, hasCapacity);
            euint32 granted = FHE.select(valid, b.requestedTonnes, FHE.asEuint32(0));
            remaining = FHE.sub(remaining, granted);
            p.soldTonnes = FHE.add(p.soldTonnes, granted);
            b.allocatedTonnes = granted;
            FHE.allowThis(remaining);
            FHE.allowThis(p.soldTonnes);
            FHE.allowThis(b.allocatedTonnes);
            FHE.allow(b.allocatedTonnes, cs[i]);
        }
        emit AllocationComplete(poolId);
    }
}
