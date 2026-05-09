// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CarbonCreditAuction - Confidential auction for verified carbon offset credits
contract CarbonCreditAuction is ZamaEthereumConfig, Ownable {
    struct CreditBatch {
        string projectId;
        uint32 tonnesCO2;
        string vintage;
        euint64 floorPrice;
        euint64 clearingPrice;
        eaddress encWinner;
        address revealedWinner;
        uint256 closeTime;
        bool settled;
    }

    mapping(uint256 => CreditBatch) public batches;
    mapping(uint256 => mapping(address => euint64)) private offers;
    mapping(address => bool) public verifiedBuyers;
    uint256 public batchCount;

    event BatchListed(uint256 indexed batchId, string projectId, uint32 tonnes);
    event OfferSubmitted(uint256 indexed batchId, address indexed buyer);
    event BatchSettled(uint256 indexed batchId, address indexed buyer);

    constructor() Ownable(msg.sender) {}

    function verifyBuyer(address buyer) external onlyOwner {
        verifiedBuyers[buyer] = true;
    }

    function listBatch(
        string calldata projectId,
        uint32 tonnesCO2,
        string calldata vintage,
        uint256 duration,
        externalEuint64 encFloor,
        bytes calldata inputProof
    ) external onlyOwner returns (uint256 batchId) {
        batchId = batchCount++;
        CreditBatch storage b = batches[batchId];
        b.projectId = projectId;
        b.tonnesCO2 = tonnesCO2;
        b.vintage = vintage;
        b.floorPrice = FHE.fromExternal(encFloor, inputProof);
        b.clearingPrice = FHE.asEuint64(0);
        b.encWinner = FHE.asEaddress(address(0));
        b.closeTime = block.timestamp + duration;
        FHE.allowThis(b.floorPrice);
        FHE.allowThis(b.clearingPrice);
        FHE.allowThis(b.encWinner);
        emit BatchListed(batchId, projectId, tonnesCO2);
    }

    function submitOffer(uint256 batchId, externalEuint64 encOffer, bytes calldata inputProof) external {
        require(verifiedBuyers[msg.sender], "Not verified");
        CreditBatch storage b = batches[batchId];
        require(block.timestamp <= b.closeTime, "Closed");
        require(!b.settled, "Settled");

        euint64 offer = FHE.fromExternal(encOffer, inputProof);
        offers[batchId][msg.sender] = offer;
        FHE.allowThis(offers[batchId][msg.sender]);

        ebool isHigher = FHE.gt(offer, b.clearingPrice);
        b.clearingPrice = FHE.select(isHigher, offer, b.clearingPrice);
        b.encWinner = FHE.select(isHigher, FHE.asEaddress(msg.sender), b.encWinner);
        FHE.allowThis(b.clearingPrice);
        FHE.allowThis(b.encWinner);
        emit OfferSubmitted(batchId, msg.sender);
    }

    function settleBatch(uint256 batchId, address winner) external onlyOwner {
        CreditBatch storage b = batches[batchId];
        require(block.timestamp > b.closeTime, "Not closed");
        require(!b.settled, "Done");
        b.settled = true;
        b.revealedWinner = winner;
        FHE.allow(b.clearingPrice, winner);
        FHE.allow(b.clearingPrice, owner());
        FHE.allow(b.encWinner, owner());
        emit BatchSettled(batchId, winner);
    }
}
