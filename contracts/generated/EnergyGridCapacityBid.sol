// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EnergyGridCapacityBid - Electricity producers bid to supply grid capacity privately
contract EnergyGridCapacityBid is ZamaEthereumConfig, Ownable {
    struct CapacityBlock {
        string region; uint256 megawattsRequired; uint256 deliveryDate;
        euint64 lowestAcceptedPrice; address winner; bool awarded;
        uint256 deadline;
    }
    mapping(uint256 => CapacityBlock) private blocks;
    mapping(uint256 => mapping(address => euint64)) private _offers;
    mapping(address => bool) public isProducer;
    uint256 public blockCount;

    event BlockCreated(uint256 indexed id); event OfferSubmitted(uint256 indexed id, address producer);
    event BlockAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}
    function addProducer(address p) external onlyOwner { isProducer[p] = true; }

    function createBlock(string calldata region, uint256 mw, uint256 deliveryDate, uint256 durationDays)
        external onlyOwner returns (uint256 id) {
        id = blockCount++;
        blocks[id] = CapacityBlock({ region: region, megawattsRequired: mw, deliveryDate: deliveryDate,
            lowestAcceptedPrice: FHE.asEuint64(type(uint64).max), winner: address(0), awarded: false,
            deadline: block.timestamp + durationDays * 1 days });
        FHE.allowThis(blocks[id].lowestAcceptedPrice);
        emit BlockCreated(id);
    }

    function submitOffer(uint256 blockId, externalEuint64 encPrice, bytes calldata proof) external {
        require(isProducer[msg.sender] && !blocks[blockId].awarded && block.timestamp < blocks[blockId].deadline, "Invalid");
        euint64 price = FHE.fromExternal(encPrice, proof);
        _offers[blockId][msg.sender] = price;
        ebool isLower = FHE.lt(price, blocks[blockId].lowestAcceptedPrice);
        blocks[blockId].lowestAcceptedPrice = FHE.select(isLower, price, blocks[blockId].lowestAcceptedPrice);
        if (FHE.isInitialized(isLower)) blocks[blockId].winner = msg.sender;
        FHE.allowThis(_offers[blockId][msg.sender]);
        FHE.allowThis(blocks[blockId].lowestAcceptedPrice);
        emit OfferSubmitted(blockId, msg.sender);
    }

    function awardBlock(uint256 blockId) external onlyOwner {
        require(block.timestamp >= blocks[blockId].deadline && !blocks[blockId].awarded, "Not ready");
        blocks[blockId].awarded = true;
        FHE.allow(blocks[blockId].lowestAcceptedPrice, blocks[blockId].winner);
        FHE.allow(blocks[blockId].lowestAcceptedPrice, owner());
        emit BlockAwarded(blockId, blocks[blockId].winner);
    }

    function allowBlockDetails(uint256 blockId, address viewer) external onlyOwner {
        FHE.allow(blocks[blockId].lowestAcceptedPrice, viewer);
    }
}
