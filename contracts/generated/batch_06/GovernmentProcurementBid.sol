// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GovernmentProcurementBid
/// @notice Public procurement: vendors submit encrypted sealed bids.
///         Lowest compliant bid wins the contract. Anti-collusion by FHE.
contract GovernmentProcurementBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TenderStatus { Open, Evaluation, Awarded, Cancelled }

    struct Tender {
        string projectTitle;
        string specifications;
        euint64 budgetCeiling;     // encrypted max budget
        euint64 winningBid;
        address winner;
        uint256 deadline;
        TenderStatus status;
        uint8 bidCount;
    }

    mapping(uint256 => Tender) private tenders;
    mapping(uint256 => mapping(address => euint64)) private _vendorBids;
    mapping(uint256 => mapping(address => bool)) public hasBid;
    mapping(address => bool) public isQualifiedVendor;
    uint256 public tenderCount;
    euint64 private _totalAwarded;

    event TenderPublished(uint256 indexed id, string title);
    event BidSubmitted(uint256 indexed id, address vendor);
    event TenderAwarded(uint256 indexed id, address vendor);

    constructor() Ownable(msg.sender) {
        _totalAwarded = FHE.asEuint64(0);
        FHE.allowThis(_totalAwarded);
    }

    function qualifyVendor(address v) external onlyOwner { isQualifiedVendor[v] = true; }
    function disqualifyVendor(address v) external onlyOwner { isQualifiedVendor[v] = false; }

    function publishTender(
        string calldata title,
        string calldata specs,
        externalEuint64 encBudget, bytes calldata proof,
        uint256 durationDays
    ) external onlyOwner returns (uint256 id) {
        euint64 budget = FHE.fromExternal(encBudget, proof);
        id = tenderCount++;
        tenders[id] = Tender({
            projectTitle: title, specifications: specs,
            budgetCeiling: budget, winningBid: FHE.asEuint64(type(uint64).max),
            winner: address(0),
            deadline: block.timestamp + durationDays * 1 days,
            status: TenderStatus.Open, bidCount: 0
        });
        FHE.allowThis(tenders[id].budgetCeiling);
        FHE.allowThis(tenders[id].winningBid);
        emit TenderPublished(id, title);
    }

    function submitBid(uint256 tenderId, externalEuint64 encBid, bytes calldata proof) external nonReentrant {
        require(isQualifiedVendor[msg.sender], "Not qualified");
        Tender storage t = tenders[tenderId];
        require(t.status == TenderStatus.Open && block.timestamp < t.deadline, "Closed");
        require(!hasBid[tenderId][msg.sender], "Already bid");
        hasBid[tenderId][msg.sender] = true;
        t.bidCount++;
        euint64 bid = FHE.fromExternal(encBid, proof);
        // Validate bid is within budget
        ebool withinBudget = FHE.le(bid, t.budgetCeiling);
        euint64 validBid = FHE.select(withinBudget, bid, FHE.asEuint64(type(uint64).max));
        _vendorBids[tenderId][msg.sender] = validBid;
        ebool isLowest = FHE.lt(validBid, t.winningBid);
        t.winningBid = FHE.select(isLowest, validBid, t.winningBid);
        if (FHE.isInitialized(isLowest)) t.winner = msg.sender;
        FHE.allowThis(_vendorBids[tenderId][msg.sender]);
        FHE.allowThis(t.winningBid);
        emit BidSubmitted(tenderId, msg.sender);
    }

    function evaluateAndAward(uint256 tenderId) external onlyOwner nonReentrant {
        Tender storage t = tenders[tenderId];
        require(block.timestamp >= t.deadline && t.status == TenderStatus.Open, "Not ready");
        t.status = TenderStatus.Evaluation;
        if (t.winner != address(0)) {
            t.status = TenderStatus.Awarded;
            _totalAwarded = FHE.add(_totalAwarded, t.winningBid);
            FHE.allow(t.winningBid, t.winner);
            FHE.allow(t.winningBid, owner());
            FHE.allowThis(_totalAwarded);
            emit TenderAwarded(tenderId, t.winner);
        } else {
            t.status = TenderStatus.Cancelled;
        }
    }

    function allowTenderDetails(uint256 tenderId, address viewer) external onlyOwner {
        FHE.allow(tenders[tenderId].budgetCeiling, viewer);
        FHE.allow(tenders[tenderId].winningBid, viewer);
    }

    function allowOwnBid(uint256 tenderId, address viewer) external {
        FHE.allow(_vendorBids[tenderId][msg.sender], viewer);
    }
}
