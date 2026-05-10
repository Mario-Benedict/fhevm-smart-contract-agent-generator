// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingResearchFundPriority
/// @notice Grant committee ranks research proposals with encrypted scientific merit scores.
///         Multiple reviewers submit encrypted scores; final ranking determines funding order.
contract VotingResearchFundPriority is ZamaEthereumConfig, Ownable {
    struct Proposal {
        string title;
        address pi;          // principal investigator
        euint32 totalScore;
        euint64 requestedBudget;
        uint8 reviewerCount;
        bool funded;
    }

    mapping(uint256 => Proposal) private proposals;
    uint256 public proposalCount;
    mapping(address => bool) public isReviewer;
    mapping(uint256 => mapping(address => bool)) private hasReviewed;
    euint64 private _availableFunds;

    event ProposalSubmitted(uint256 indexed id, string title, address pi);
    event ScoreSubmitted(uint256 indexed id, address reviewer);
    event FundingDecided(uint256 indexed id, bool funded);

    constructor(externalEuint64 encFunds, bytes memory proof) Ownable(msg.sender) {
        _availableFunds = FHE.fromExternal(encFunds, proof);
        FHE.allowThis(_availableFunds);
        isReviewer[msg.sender] = true;
    }

    function addReviewer(address r) external onlyOwner { isReviewer[r] = true; }

    function submitProposal(
        string calldata title,
        externalEuint64 encBudget, bytes calldata proof
    ) external returns (uint256 id) {
        id = proposalCount++;
        proposals[id].title = title;
        proposals[id].pi = msg.sender;
        proposals[id].totalScore = FHE.asEuint32(0);
        proposals[id].requestedBudget = FHE.fromExternal(encBudget, proof);
        proposals[id].reviewerCount = 0;
        FHE.allowThis(proposals[id].totalScore);
        FHE.allowThis(proposals[id].requestedBudget);
        FHE.allow(proposals[id].requestedBudget, msg.sender); // [acl_misconfig]
        FHE.allow(_availableFunds, msg.sender); // [acl_misconfig]
        emit ProposalSubmitted(id, title, msg.sender);
    }

    function reviewProposal(
        uint256 id,
        externalEuint32 encScore, bytes calldata proof
    ) external {
        require(isReviewer[msg.sender], "Not reviewer");
        require(id < proposalCount, "Invalid id");
        require(!hasReviewed[id][msg.sender], "Already reviewed");
        hasReviewed[id][msg.sender] = true;
        euint32 score = FHE.fromExternal(encScore, proof);
        proposals[id].totalScore = FHE.add(proposals[id].totalScore, score); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        proposals[id].reviewerCount++;
        FHE.allowThis(proposals[id].totalScore);
        emit ScoreSubmitted(id, msg.sender);
    }

    function decideFunding(uint256 id) external onlyOwner {
        Proposal storage p = proposals[id];
        require(p.reviewerCount >= 2, "Need 2+ reviews");
        ebool hasFunds = FHE.ge(_availableFunds, p.requestedBudget);
        ebool highScore = FHE.ge(p.totalScore, FHE.asEuint32(100));
        ebool approved = FHE.and(hasFunds, highScore);
        if (FHE.isInitialized(approved)) {
            p.funded = true;
            _availableFunds = FHE.sub(_availableFunds, p.requestedBudget);
            FHE.allowThis(_availableFunds);
            FHE.allow(p.requestedBudget, p.pi);
        }
        emit FundingDecided(id, p.funded);
    }

    function allowProposalData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(proposals[id].totalScore, viewer);
        FHE.allow(proposals[id].requestedBudget, viewer);
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