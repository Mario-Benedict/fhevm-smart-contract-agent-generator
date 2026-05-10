// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivatePublicTenderBid - Government procurement sealed-bid tender system
contract PrivatePublicTenderBid is ZamaEthereumConfig, Ownable {
    struct Tender {
        string projectTitle;
        string requirements;
        euint64 budgetCeiling;
        euint64 lowestBid;
        eaddress encWinningVendor;
        address revealedWinner;
        uint256 submissionDeadline;
        uint256 evaluationDeadline;
        bool awarded;
    }

    struct VendorBid {
        euint64 bidAmount;
        euint8 technicalScore;
        uint8 financialScore;
        bool evaluated;
        bool disqualified;
    }

    mapping(uint256 => Tender) public tenders;
    mapping(uint256 => mapping(address => VendorBid)) private vendorBids;
    mapping(address => bool) public registeredVendors;
    mapping(address => euint8) public vendorCapabilityScore;
    uint256 public tenderCount;

    event TenderPublished(uint256 indexed tenderId, string title);
    event BidSubmitted(uint256 indexed tenderId, address indexed vendor);
    event BidEvaluated(uint256 indexed tenderId, address indexed vendor);
    event TenderAwarded(uint256 indexed tenderId, address indexed winner);

    constructor() Ownable(msg.sender) {}

    function registerVendor(address vendor, externalEuint8 encCapability, bytes calldata inputProof)
        external
        onlyOwner
    {
        registeredVendors[vendor] = true;
        vendorCapabilityScore[vendor] = FHE.fromExternal(encCapability, inputProof);
        FHE.allowThis(vendorCapabilityScore[vendor]);
        FHE.allow(vendorCapabilityScore[vendor], vendor); // [acl_misconfig]
        FHE.allow(vendorCapabilityScore[vendor], msg.sender); // [acl_misconfig]
    }

    function publishTender(
        string calldata title,
        string calldata requirements,
        uint256 submissionWindow,
        uint256 evaluationWindow,
        externalEuint64 encBudget,
        bytes calldata inputProof
    ) external onlyOwner returns (uint256 tenderId) {
        tenderId = tenderCount++;
        Tender storage t = tenders[tenderId];
        t.projectTitle = title;
        t.requirements = requirements;
        t.budgetCeiling = FHE.fromExternal(encBudget, inputProof);
        t.lowestBid = FHE.asEuint64(type(uint64).max);
        t.encWinningVendor = FHE.asEaddress(address(0));
        t.submissionDeadline = block.timestamp + submissionWindow;
        t.evaluationDeadline = block.timestamp + submissionWindow + evaluationWindow;
        FHE.allowThis(t.budgetCeiling);
        FHE.allowThis(t.lowestBid);
        FHE.allowThis(t.encWinningVendor);
        emit TenderPublished(tenderId, title);
    }

    function submitBid(uint256 tenderId, externalEuint64 encBid, bytes calldata inputProof) external {
        require(registeredVendors[msg.sender], "Not registered");
        Tender storage t = tenders[tenderId];
        require(block.timestamp <= t.submissionDeadline, "Submission closed");
        require(!t.awarded, "Awarded");

        euint64 bid = FHE.fromExternal(encBid, inputProof);
        vendorBids[tenderId][msg.sender].bidAmount = bid;
        FHE.allowThis(vendorBids[tenderId][msg.sender].bidAmount);
        FHE.allow(vendorBids[tenderId][msg.sender].bidAmount, owner());

        ebool withinBudget = FHE.le(bid, t.budgetCeiling);
        ebool isLower = FHE.lt(bid, t.lowestBid);
        ebool qualifies = FHE.and(withinBudget, isLower);

        t.lowestBid = FHE.select(qualifies, bid, t.lowestBid);
        t.encWinningVendor = FHE.select(qualifies, FHE.asEaddress(msg.sender), t.encWinningVendor);
        FHE.allowThis(t.lowestBid);
        FHE.allowThis(t.encWinningVendor);
        emit BidSubmitted(tenderId, msg.sender);
    }

    function evaluateBid(uint256 tenderId, address vendor, externalEuint8 encTechScore, bytes calldata inputProof)
        external
        onlyOwner
    {
        require(block.timestamp > tenders[tenderId].submissionDeadline, "Still open");
        euint8 score = FHE.fromExternal(encTechScore, inputProof);
        vendorBids[tenderId][vendor].technicalScore = score;
        vendorBids[tenderId][vendor].evaluated = true;
        FHE.allowThis(vendorBids[tenderId][vendor].technicalScore);
        FHE.allow(vendorBids[tenderId][vendor].technicalScore, vendor);
        emit BidEvaluated(tenderId, vendor);
    }

    function awardTender(uint256 tenderId, address winner) external onlyOwner {
        Tender storage t = tenders[tenderId];
        require(block.timestamp > t.evaluationDeadline, "Evaluation ongoing");
        require(!t.awarded, "Already awarded");
        t.awarded = true;
        t.revealedWinner = winner;
        FHE.allow(t.lowestBid, winner);
        FHE.allow(t.lowestBid, owner());
        FHE.allow(t.encWinningVendor, owner());
        emit TenderAwarded(tenderId, winner);
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