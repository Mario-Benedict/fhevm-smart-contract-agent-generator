// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SovereignDebtAuction
/// @notice Government bond auction with encrypted bids. Primary dealers submit sealed
///         yield bids; lowest yield wins. Treasury manages encrypted issuance caps.
contract SovereignDebtAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct BondOffering {
        string bondName;
        string maturity;          // e.g. "10Y", "30Y"
        uint256 faceValueUSD;     // plaintext total face value of issuance
        euint64 maxYieldBps;      // encrypted max acceptable yield (bps)
        euint64 clearingYieldBps; // encrypted clearing yield set at auction close
        euint64 totalBidCover;    // encrypted total bids received (cover ratio numerator)
        uint256 deadline;
        bool settled;
    }

    struct DealerBid {
        euint64 yieldBps;       // encrypted yield bid
        euint64 amountUSD;      // encrypted amount requested
        bool allocated;
    }

    mapping(uint256 => BondOffering) private offerings;
    mapping(uint256 => mapping(address => DealerBid)) private bids;
    mapping(address => bool) public isPrimaryDealer;
    mapping(address => bool) public isTreasury;
    uint256 public offeringCount;
    euint64 private _totalIssuanceUSD;

    event OfferingCreated(uint256 indexed id, string bond);
    event BidSubmitted(uint256 indexed id, address dealer);
    event AuctionSettled(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalIssuanceUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalIssuanceUSD);
        isTreasury[msg.sender] = true;
    }

    function addPrimaryDealer(address d) external onlyOwner { isPrimaryDealer[d] = true; }
    function addTreasury(address t) external onlyOwner { isTreasury[t] = true; }

    function createOffering(
        string calldata bondName, string calldata maturity, uint256 faceValue,
        externalEuint64 encMaxYield, bytes calldata proof, uint256 durationDays
    ) external returns (uint256 id) {
        require(isTreasury[msg.sender], "Not treasury");
        euint64 maxYield = FHE.fromExternal(encMaxYield, proof);
        euint64 maxYieldWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 maxYieldExposure = FHE.sub(maxYieldWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        id = offeringCount++;
        offerings[id] = BondOffering({
            bondName: bondName, maturity: maturity, faceValueUSD: faceValue,
            maxYieldBps: maxYield, clearingYieldBps: FHE.asEuint64(type(uint64).max),
            totalBidCover: FHE.asEuint64(0),
            deadline: block.timestamp + durationDays * 1 days, settled: false
        });
        FHE.allowThis(offerings[id].maxYieldBps);
        FHE.allowThis(offerings[id].clearingYieldBps);
        FHE.allowThis(offerings[id].totalBidCover);
        emit OfferingCreated(id, bondName);
    }

    function submitBid(
        uint256 offeringId,
        externalEuint64 encYield, bytes calldata yProof,
        externalEuint64 encAmount, bytes calldata aProof
    ) external nonReentrant {
        require(isPrimaryDealer[msg.sender], "Not dealer");
        BondOffering storage o = offerings[offeringId];
        require(!o.settled && block.timestamp < o.deadline, "Closed");
        euint64 yield_ = FHE.fromExternal(encYield, yProof);
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        // Only accept if yield <= maxYield
        ebool acceptable = FHE.le(yield_, o.maxYieldBps);
        euint64 acceptedYield = FHE.select(acceptable, yield_, FHE.asEuint64(type(uint64).max));
        bids[offeringId][msg.sender] = DealerBid({ yieldBps: acceptedYield, amountUSD: amount, allocated: false });
        o.totalBidCover = FHE.add(o.totalBidCover, amount);
        // Track clearing yield (lowest yield wins = best price for treasury)
        ebool isLower = FHE.lt(acceptedYield, o.clearingYieldBps);
        o.clearingYieldBps = FHE.select(isLower, acceptedYield, o.clearingYieldBps);
        FHE.allowThis(bids[offeringId][msg.sender].yieldBps);
        FHE.allow(bids[offeringId][msg.sender].yieldBps, msg.sender);
        FHE.allowThis(bids[offeringId][msg.sender].amountUSD);
        FHE.allowThis(o.totalBidCover);
        FHE.allowThis(o.clearingYieldBps);
        emit BidSubmitted(offeringId, msg.sender);
    }

    function settleAuction(uint256 offeringId) external {
        require(isTreasury[msg.sender], "Not treasury");
        BondOffering storage o = offerings[offeringId];
        require(block.timestamp >= o.deadline && !o.settled, "Not ready");
        o.settled = true;
        _totalIssuanceUSD = FHE.add(_totalIssuanceUSD, FHE.asEuint64(uint64(o.faceValueUSD)));
        FHE.allowThis(_totalIssuanceUSD);
        FHE.allow(o.clearingYieldBps, msg.sender);
        FHE.allow(o.totalBidCover, msg.sender);
        emit AuctionSettled(offeringId);
    }

    function allowOfferingDetails(uint256 id, address viewer) external {
        require(isTreasury[msg.sender], "Not treasury");
        FHE.allow(offerings[id].maxYieldBps, viewer);
        FHE.allow(offerings[id].clearingYieldBps, viewer);
        FHE.allow(offerings[id].totalBidCover, viewer);
    }

    function allowOwnBid(uint256 offeringId, address viewer) external {
        FHE.allow(bids[offeringId][msg.sender].yieldBps, viewer);
        FHE.allow(bids[offeringId][msg.sender].amountUSD, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}