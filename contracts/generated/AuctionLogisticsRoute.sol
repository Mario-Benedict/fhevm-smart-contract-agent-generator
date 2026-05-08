// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionLogisticsRoute
/// @notice Logistics contract auction where carriers bid encrypted price/ton rates.
///         Shippers enforce encrypted minimum service level agreements (SLA scores).
contract AuctionLogisticsRoute is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LogisticsContract {
        string routeDescription;
        euint64 maxPricePerTon;
        euint8 minSLAScore;
        euint32 estimatedTonsPerYear;
        uint256 auctionEnd;
        bool finalized;
        address carrier;
        euint64 winningPrice;
    }

    struct CarrierBid {
        euint64 pricePerTon;
        euint8 slaScore;
        euint8 safetyRating;
        bool placed;
    }

    mapping(uint256 => LogisticsContract) private contracts;
    uint256 public contractCount;
    mapping(uint256 => mapping(address => CarrierBid)) private bids;
    mapping(uint256 => address[]) private carriers;
    mapping(address => bool) public isRegisteredCarrier;

    event ContractListed(uint256 indexed id, string route);
    event BidSubmitted(uint256 indexed id, address carrier);
    event ContractAwarded(uint256 indexed id, address carrier);

    constructor() Ownable(msg.sender) {}

    function registerCarrier(address c) external onlyOwner { isRegisteredCarrier[c] = true; }

    function listContract(
        string calldata route, uint32 tons,
        externalEuint64 encMaxPrice, bytes calldata pProof,
        externalEuint8 encMinSLA, bytes calldata sProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = contractCount++;
        contracts[id].routeDescription = route;
        contracts[id].estimatedTonsPerYear = FHE.asEuint32(tons);
        contracts[id].maxPricePerTon = FHE.fromExternal(encMaxPrice, pProof);
        contracts[id].minSLAScore = FHE.fromExternal(encMinSLA, sProof);
        contracts[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        contracts[id].winningPrice = FHE.asEuint64(0);
        FHE.allowThis(contracts[id].estimatedTonsPerYear);
        FHE.allowThis(contracts[id].maxPricePerTon);
        FHE.allowThis(contracts[id].minSLAScore);
        FHE.allowThis(contracts[id].winningPrice);
        emit ContractListed(id, route);
    }

    function submitBid(
        uint256 contractId,
        externalEuint64 encPrice, bytes calldata pProof,
        externalEuint8 encSLA, bytes calldata sProof,
        externalEuint8 encSafety, bytes calldata saProof
    ) external nonReentrant {
        require(isRegisteredCarrier[msg.sender], "Not registered");
        LogisticsContract storage lc = contracts[contractId];
        require(block.timestamp < lc.auctionEnd, "Closed");
        require(!bids[contractId][msg.sender].placed, "Already bid");
        bids[contractId][msg.sender] = CarrierBid({
            pricePerTon: FHE.fromExternal(encPrice, pProof),
            slaScore: FHE.fromExternal(encSLA, sProof),
            safetyRating: FHE.fromExternal(encSafety, saProof),
            placed: true
        });
        FHE.allowThis(bids[contractId][msg.sender].pricePerTon);
        FHE.allowThis(bids[contractId][msg.sender].slaScore);
        FHE.allowThis(bids[contractId][msg.sender].safetyRating);
        carriers[contractId].push(msg.sender);
        emit BidSubmitted(contractId, msg.sender);
    }

    function awardContract(uint256 contractId) external onlyOwner nonReentrant {
        LogisticsContract storage lc = contracts[contractId];
        require(block.timestamp >= lc.auctionEnd && !lc.finalized, "Cannot award");
        lc.finalized = true;
        euint64 bestPrice = FHE.asEuint64(type(uint64).max);
        address bestCarrier = address(0);
        address[] storage cs = carriers[contractId];
        for (uint256 i = 0; i < cs.length; i++) {
            CarrierBid storage b = bids[contractId][cs[i]];
            ebool slaOk = FHE.ge(b.slaScore, lc.minSLAScore);
            ebool priceOk = FHE.le(b.pricePerTon, lc.maxPricePerTon);
            ebool valid = FHE.and(slaOk, priceOk);
            ebool isBest = FHE.lt(b.pricePerTon, bestPrice);
            ebool winner = FHE.and(valid, isBest);
            bestPrice = FHE.select(winner, b.pricePerTon, bestPrice);
            if (FHE.isInitialized(winner)) bestCarrier = cs[i];
        }
        lc.carrier = bestCarrier;
        lc.winningPrice = bestPrice;
        FHE.allowThis(lc.winningPrice);
        if (bestCarrier != address(0)) FHE.allow(lc.winningPrice, bestCarrier);
        emit ContractAwarded(contractId, bestCarrier);
    }
}
