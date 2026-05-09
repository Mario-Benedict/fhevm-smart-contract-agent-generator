// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMergerAcquisitionEscrow
/// @notice M&A deal escrow: encrypted deal price, encrypted earnout milestones,
///         encrypted breakup fee. Funds released upon encrypted condition satisfaction.
contract PrivateMergerAcquisitionEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DealStatus { InDueDiligence, Signed, EscrowFunded, Completed, Broken }
    enum MilestoneStatus { Pending, Achieved, Missed }

    struct Deal {
        address buyer;
        address seller;
        string targetCompany;
        euint64 totalConsiderationUSD;   // encrypted total deal value
        euint64 escrowedAmountUSD;       // encrypted escrow deposit
        euint64 breakupFeeUSD;           // encrypted breakup fee
        euint64 earnoutTotalUSD;         // encrypted earnout pool
        euint64 earnoutReleasedUSD;      // encrypted earnout released
        uint256 closingDeadline;
        DealStatus status;
    }

    struct Earnout {
        uint256 dealId;
        string metricName;
        euint64 targetValueUSD;          // encrypted target metric value
        euint64 actualValueUSD;          // encrypted actual metric
        euint64 earnoutAmountUSD;        // encrypted earnout tied to milestone
        MilestoneStatus status;
        uint256 measurementDate;
    }

    mapping(uint256 => Deal) private deals;
    mapping(uint256 => Earnout) private earnouts;
    mapping(uint256 => uint256[]) private dealEarnouts;
    mapping(address => bool) public isArbitrator;

    uint256 public dealCount;
    uint256 public earnoutCount;
    euint64 private _totalDealValueUSD;

    event DealCreated(uint256 indexed id, address buyer, address seller);
    event EscrowFunded(uint256 indexed id);
    event DealClosed(uint256 indexed id);
    event DealBroken(uint256 indexed id);
    event EarnoutAchieved(uint256 indexed earnoutId, uint256 dealId);

    modifier onlyArbitrator() {
        require(isArbitrator[msg.sender] || msg.sender == owner(), "Not arbitrator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDealValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalDealValueUSD);
        isArbitrator[msg.sender] = true;
    }

    function addArbitrator(address a) external onlyOwner { isArbitrator[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createDeal(
        address seller,
        string calldata targetCompany,
        externalEuint64 encConsideration, bytes calldata cProof,
        externalEuint64 encEscrow, bytes calldata eProof,
        externalEuint64 encBreakup, bytes calldata bProof,
        externalEuint64 encEarnout, bytes calldata enProof,
        uint256 closingDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 consideration = FHE.fromExternal(encConsideration, cProof);
        euint64 escrow = FHE.fromExternal(encEscrow, eProof);
        euint64 breakup = FHE.fromExternal(encBreakup, bProof);
        euint64 earnout = FHE.fromExternal(encEarnout, enProof);
        id = dealCount++;
        deals[id].buyer = msg.sender;
        deals[id].seller = seller;
        deals[id].targetCompany = targetCompany;
        deals[id].totalConsiderationUSD = consideration;
        deals[id].escrowedAmountUSD = escrow;
        deals[id].breakupFeeUSD = breakup;
        deals[id].earnoutTotalUSD = earnout;
        deals[id].earnoutReleasedUSD = FHE.asEuint64(0);
        deals[id].closingDeadline = block.timestamp + closingDays * 1 days;
        deals[id].status = DealStatus.InDueDiligence;
        _totalDealValueUSD = FHE.add(_totalDealValueUSD, consideration);
        FHE.allowThis(deals[id].totalConsiderationUSD);
        FHE.allow(deals[id].totalConsiderationUSD, msg.sender);
        FHE.allow(deals[id].totalConsiderationUSD, seller);
        FHE.allowThis(deals[id].escrowedAmountUSD);
        FHE.allowThis(deals[id].breakupFeeUSD);
        FHE.allowThis(deals[id].earnoutTotalUSD);
        FHE.allowThis(deals[id].earnoutReleasedUSD);
        FHE.allowThis(_totalDealValueUSD);
        emit DealCreated(id, msg.sender, seller);
    }

    function addEarnout(
        uint256 dealId,
        string calldata metricName,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint64 encEarnoutAmt, bytes calldata aProof,
        uint256 measurementDays
    ) external {
        Deal storage d = deals[dealId];
        require(d.buyer == msg.sender, "Not buyer");
        euint64 target = FHE.fromExternal(encTarget, tProof);
        euint64 earnoutAmt = FHE.fromExternal(encEarnoutAmt, aProof);
        uint256 eid = earnoutCount++;
        earnouts[eid] = Earnout({
            dealId: dealId, metricName: metricName,
            targetValueUSD: target, actualValueUSD: FHE.asEuint64(0),
            earnoutAmountUSD: earnoutAmt,
            status: MilestoneStatus.Pending,
            measurementDate: block.timestamp + measurementDays * 1 days
        });
        FHE.allowThis(earnouts[eid].targetValueUSD);
        FHE.allow(earnouts[eid].targetValueUSD, d.seller);
        FHE.allowThis(earnouts[eid].actualValueUSD);
        FHE.allowThis(earnouts[eid].earnoutAmountUSD);
        dealEarnouts[dealId].push(eid);
    }

    function reportEarnoutActual(
        uint256 earnoutId,
        externalEuint64 encActual, bytes calldata proof
    ) external onlyArbitrator {
        Earnout storage e = earnouts[earnoutId];
        require(block.timestamp >= e.measurementDate, "Too early");
        euint64 actual = FHE.fromExternal(encActual, proof);
        e.actualValueUSD = actual;
        ebool achieved = FHE.ge(actual, e.targetValueUSD);
        e.status = FHE.isInitialized(achieved) ? MilestoneStatus.Achieved : MilestoneStatus.Missed;
        if (e.status == MilestoneStatus.Achieved) {
            Deal storage d = deals[e.dealId];
            d.earnoutReleasedUSD = FHE.add(d.earnoutReleasedUSD, e.earnoutAmountUSD);
            FHE.allowThis(d.earnoutReleasedUSD);
            FHE.allow(d.earnoutReleasedUSD, d.seller);
            emit EarnoutAchieved(earnoutId, e.dealId);
        }
        FHE.allowThis(e.actualValueUSD);
        FHE.allow(e.actualValueUSD, deals[e.dealId].seller);
    }

    function fundEscrow(uint256 dealId) external {
        Deal storage d = deals[dealId];
        require(d.buyer == msg.sender && d.status == DealStatus.Signed, "Cannot fund");
        d.status = DealStatus.EscrowFunded;
        emit EscrowFunded(dealId);
    }

    function closeDeal(uint256 dealId) external onlyArbitrator {
        deals[dealId].status = DealStatus.Completed;
        emit DealClosed(dealId);
    }

    function breakDeal(uint256 dealId) external onlyArbitrator {
        deals[dealId].status = DealStatus.Broken;
        emit DealBroken(dealId);
    }

    function allowDealDetails(uint256 dealId, address viewer) external {
        Deal storage d = deals[dealId];
        require(msg.sender == d.buyer || msg.sender == d.seller || isArbitrator[msg.sender], "Unauthorized");
        FHE.allow(d.totalConsiderationUSD, viewer);
        FHE.allow(d.escrowedAmountUSD, viewer);
        FHE.allow(d.breakupFeeUSD, viewer);
        FHE.allow(d.earnoutTotalUSD, viewer);
        FHE.allow(d.earnoutReleasedUSD, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalDealValueUSD, viewer);
    }
}
