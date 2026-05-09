// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateCarbonOffsetAuction - Sealed carbon offset credit auction for ESG-compliant firms
contract PrivateCarbonOffsetAuction is ZamaEthereumConfig, Ownable {
    struct OffsetLot { string projectName; string certifier; uint256 tonsOfCO2; uint256 vintage;
        euint64 priceFloor; euint64 highestBid; address highestBidder; uint256 deadline; bool sold; }
    mapping(uint256 => OffsetLot) private lots;
    mapping(uint256 => mapping(address => euint64)) private _bids;
    mapping(address => bool) public isESGEntity;
    uint256 public lotCount;

    event LotCreated(uint256 indexed id, string project); event BidPlaced(uint256 indexed id, address entity);
    event LotSold(uint256 indexed id, address buyer);

    constructor() Ownable(msg.sender) {}
    function addESGEntity(address e) external onlyOwner { isESGEntity[e] = true; }

    function createLot(string calldata project, string calldata certifier, uint256 tons, uint256 vintage,
        externalEuint64 encFloor, bytes calldata proof, uint256 days_) external onlyOwner returns (uint256 id) {
        euint64 floor = FHE.fromExternal(encFloor, proof);
        id = lotCount++;
        lots[id].projectName = project;
        lots[id].certifier = certifier;
        lots[id].tonsOfCO2 = tons;
        lots[id].vintage = vintage;
        lots[id].priceFloor = floor;
        lots[id].highestBid = FHE.asEuint64(0);
        lots[id].highestBidder = address(0);
        lots[id].deadline = block.timestamp + days_ * 1 days;
        lots[id].sold = false;
        FHE.allowThis(lots[id].priceFloor); FHE.allowThis(lots[id].highestBid);
        emit LotCreated(id, project);
    }

    function bid(uint256 lotId, externalEuint64 encBid, bytes calldata proof) external {
        require(isESGEntity[msg.sender] && !lots[lotId].sold && block.timestamp < lots[lotId].deadline, "Invalid");
        euint64 bidAmt = FHE.fromExternal(encBid, proof);
        _bids[lotId][msg.sender] = bidAmt;
        ebool isHigher = FHE.gt(bidAmt, lots[lotId].highestBid);
        lots[lotId].highestBid = FHE.select(isHigher, bidAmt, lots[lotId].highestBid);
        if (FHE.isInitialized(isHigher)) lots[lotId].highestBidder = msg.sender;
        FHE.allowThis(_bids[lotId][msg.sender]); FHE.allowThis(lots[lotId].highestBid);
        emit BidPlaced(lotId, msg.sender);
    }

    function finalize(uint256 lotId) external onlyOwner {
        OffsetLot storage lot = lots[lotId];
        require(block.timestamp >= lot.deadline && !lot.sold, "Not ready");
        lot.sold = true;
        ebool ok = FHE.ge(lot.highestBid, lot.priceFloor);
        if (FHE.isInitialized(ok) && lot.highestBidder != address(0)) {
            FHE.allow(lot.highestBid, lot.highestBidder);
            FHE.allow(lot.highestBid, owner());
            emit LotSold(lotId, lot.highestBidder);
        }
    }

    function allowLotDetails(uint256 id, address viewer) external onlyOwner {
        FHE.allow(lots[id].priceFloor, viewer); FHE.allow(lots[id].highestBid, viewer);
    }
}
