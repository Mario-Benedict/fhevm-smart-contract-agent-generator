// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSovereignBondAuction
/// @notice Government sovereign bond primary auction: encrypted bid quantities, hidden yield
///         demands, confidential total issuance allocation, and private competitive/non-competitive
///         bid weighting for central bank primary dealer network.
contract PrivateSovereignBondAuction is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BidType { Competitive, NonCompetitive }
    enum AuctionState { Announced, BiddingOpen, BiddingClosed, Allotted, Settled }

    struct BondIssuance {
        string bondSeries;
        string maturityLabel;
        uint256 maturityDate;
        euint64 totalIssuanceFaceUSD;  // encrypted total face value
        euint64 allottedAmountUSD;     // encrypted amount allotted
        euint16 couponRateBps;         // encrypted coupon rate
        euint16 cutoffYieldBps;        // encrypted stop-out yield
        euint16 averageYieldBps;       // encrypted weighted avg yield
        AuctionState state;
        uint256 auctionDate;
    }

    struct DealerBid {
        uint256 issuanceId;
        address primaryDealer;
        BidType bidType;
        euint64 faceAmountUSD;         // encrypted bid face value
        euint16 yieldBps;              // encrypted bid yield (competitive)
        euint64 allottedAmountUSD;     // encrypted allotted amount
        bool allotted;
    }

    mapping(uint256 => BondIssuance) private issuances;
    mapping(uint256 => DealerBid) private dealerBids;
    mapping(address => bool) public isPrimaryDealer;
    mapping(address => bool) public isCentralBank;

    uint256 public issuanceCount;
    uint256 public bidCount;
    euint64 private _totalIssuedFaceValueUSD;
    euint64 private _totalBidCoverageUSD;

    event BondAuctionAnnounced(uint256 indexed id, string bondSeries, uint256 auctionDate);
    event BidSubmitted(uint256 indexed bidId, uint256 issuanceId, BidType bidType);
    event AuctionAllotted(uint256 indexed issuanceId);

    modifier onlyPrimaryDealer() {
        require(isPrimaryDealer[msg.sender] || msg.sender == owner(), "Not primary dealer");
        _;
    }

    modifier onlyCentralBank() {
        require(isCentralBank[msg.sender] || msg.sender == owner(), "Not central bank");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalIssuedFaceValueUSD = FHE.asEuint64(0);
        _totalBidCoverageUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalIssuedFaceValueUSD);
        FHE.allowThis(_totalBidCoverageUSD);
        isCentralBank[msg.sender] = true;
        isPrimaryDealer[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addPrimaryDealer(address d) external onlyOwner { isPrimaryDealer[d] = true; }
    function addCentralBank(address cb) external onlyOwner { isCentralBank[cb] = true; }

    function announceAuction(
        string calldata bondSeries,
        string calldata maturityLabel,
        uint256 maturityDate,
        externalEuint64 encTotalIssuance, bytes calldata tiProof,
        externalEuint16 encCouponRate, bytes calldata crProof,
        uint256 auctionDate
    ) external onlyCentralBank whenNotPaused returns (uint256 id) {
        euint64 totalIssue = FHE.fromExternal(encTotalIssuance, tiProof);
        euint16 couponRate = FHE.fromExternal(encCouponRate, crProof);
        id = issuanceCount++;
        issuances[id].bondSeries = bondSeries;
        issuances[id].maturityLabel = maturityLabel;
        issuances[id].maturityDate = maturityDate;
        issuances[id].totalIssuanceFaceUSD = totalIssue;
        issuances[id].allottedAmountUSD = FHE.asEuint64(0);
        issuances[id].couponRateBps = couponRate;
        issuances[id].cutoffYieldBps = FHE.asEuint16(0);
        issuances[id].averageYieldBps = FHE.asEuint16(0);
        issuances[id].state = AuctionState.Announced;
        issuances[id].auctionDate = auctionDate;
        FHE.allowThis(issuances[id].totalIssuanceFaceUSD);
        FHE.allowThis(issuances[id].allottedAmountUSD);
        FHE.allowThis(issuances[id].couponRateBps);
        FHE.allowThis(issuances[id].cutoffYieldBps);
        FHE.allowThis(issuances[id].averageYieldBps);
        emit BondAuctionAnnounced(id, bondSeries, auctionDate);
    }

    function openBidding(uint256 issuanceId) external onlyCentralBank {
        issuances[issuanceId].state = AuctionState.BiddingOpen;
    }

    function submitBid(
        uint256 issuanceId,
        BidType bidType,
        externalEuint64 encFaceAmount, bytes calldata faProof,
        externalEuint16 encYield, bytes calldata yProof
    ) external onlyPrimaryDealer whenNotPaused returns (uint256 bidId) {
        require(issuances[issuanceId].state == AuctionState.BiddingOpen, "Not open");
        euint64 faceAmount = FHE.fromExternal(encFaceAmount, faProof);
        euint16 yieldBps = FHE.fromExternal(encYield, yProof);
        bidId = bidCount++;
        dealerBids[bidId] = DealerBid({
            issuanceId: issuanceId, primaryDealer: msg.sender, bidType: bidType,
            faceAmountUSD: faceAmount, yieldBps: yieldBps,
            allottedAmountUSD: FHE.asEuint64(0), allotted: false
        });
        _totalBidCoverageUSD = FHE.add(_totalBidCoverageUSD, faceAmount);
        FHE.allowThis(dealerBids[bidId].faceAmountUSD); FHE.allow(dealerBids[bidId].faceAmountUSD, msg.sender);
        FHE.allowThis(dealerBids[bidId].yieldBps); FHE.allow(dealerBids[bidId].yieldBps, msg.sender);
        FHE.allowThis(dealerBids[bidId].allottedAmountUSD);
        FHE.allowThis(_totalBidCoverageUSD);
        emit BidSubmitted(bidId, issuanceId, bidType);
    }

    function allotIssuance(
        uint256 issuanceId,
        externalEuint64 encAllotted, bytes calldata aProof,
        externalEuint16 encCutoffYield, bytes calldata cyProof,
        externalEuint16 encAvgYield, bytes calldata ayProof
    ) external onlyCentralBank nonReentrant {
        BondIssuance storage iss = issuances[issuanceId];
        require(iss.state == AuctionState.BiddingClosed, "Not closed");
        euint64 allotted = FHE.fromExternal(encAllotted, aProof);
        euint16 cutoffYield = FHE.fromExternal(encCutoffYield, cyProof);
        euint16 avgYield = FHE.fromExternal(encAvgYield, ayProof);
        iss.allottedAmountUSD = allotted;
        iss.cutoffYieldBps = cutoffYield;
        iss.averageYieldBps = avgYield;
        iss.state = AuctionState.Allotted;
        _totalIssuedFaceValueUSD = FHE.add(_totalIssuedFaceValueUSD, allotted);
        FHE.allowThis(iss.allottedAmountUSD);
        FHE.allowThis(iss.cutoffYieldBps);
        FHE.allowThis(iss.averageYieldBps);
        FHE.allowThis(_totalIssuedFaceValueUSD);
        emit AuctionAllotted(issuanceId);
    }

    function allotDealerBid(uint256 bidId, externalEuint64 encAllotted, bytes calldata proof) external onlyCentralBank {
        DealerBid storage b = dealerBids[bidId];
        euint64 allotted = FHE.fromExternal(encAllotted, proof);
        b.allottedAmountUSD = allotted;
        b.allotted = true;
        FHE.allowThis(b.allottedAmountUSD); FHE.allow(b.allottedAmountUSD, b.primaryDealer);
    }

    function closeBidding(uint256 issuanceId) external onlyCentralBank {
        issuances[issuanceId].state = AuctionState.BiddingClosed;
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalIssuedFaceValueUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalIssuedFaceValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBidCoverageUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBidCoverageUSD, viewer);
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