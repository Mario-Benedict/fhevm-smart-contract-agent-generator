// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCharityEndowment
/// @notice Charitable endowment fund: donors contribute encrypted amounts,
///         grants disbursed to vetted nonprofits with encrypted amounts, 
///         and anonymous matching by major donor.
contract PrivateCharityEndowment is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Grant {
        address recipient;
        string purpose;
        euint64 requestedAmount;   // encrypted requested grant
        euint64 approvedAmount;    // encrypted approved disbursement
        euint64 matchedAmount;     // encrypted matching from major donor
        bool approved;
        bool disbursed;
        uint256 submittedAt;
    }

    euint64 private _endowmentBalance;    // encrypted total fund
    euint64 private _annualPayoutBps;     // encrypted payout rate e.g. 500 = 5%
    euint64 private _matchingPoolRemaining; // encrypted anonymous matching pool
    mapping(address => euint64) private _donorContributions;
    mapping(uint256 => Grant) private grants;
    mapping(address => bool) public isGrantReviewer;
    mapping(address => bool) public isVettedNonprofit;
    uint256 public grantCount;

    event DonationReceived(address indexed donor);
    event MatchingPoolAdded();
    event GrantSubmitted(uint256 indexed id, address nonprofit);
    event GrantApproved(uint256 indexed id);
    event GrantDisbursed(uint256 indexed id, address recipient);

    constructor(externalEuint64 encPayoutBps, bytes memory proof) Ownable(msg.sender) {
        _annualPayoutBps = FHE.fromExternal(encPayoutBps, proof);
        _endowmentBalance = FHE.asEuint64(0);
        _matchingPoolRemaining = FHE.asEuint64(0);
        FHE.allowThis(_annualPayoutBps);
        FHE.allowThis(_endowmentBalance);
        FHE.allowThis(_matchingPoolRemaining);
        isGrantReviewer[msg.sender] = true;
    }

    function addReviewer(address r) external onlyOwner { isGrantReviewer[r] = true; }
    function addNonprofit(address np) external onlyOwner { isVettedNonprofit[np] = true; }

    function donate(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _endowmentBalance = FHE.add(_endowmentBalance, amount);
        if (!FHE.isInitialized(_donorContributions[msg.sender])) {
            _donorContributions[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_donorContributions[msg.sender]);
        }
        _donorContributions[msg.sender] = FHE.add(_donorContributions[msg.sender], amount);
        FHE.allowThis(_endowmentBalance);
        FHE.allowThis(_donorContributions[msg.sender]);
        FHE.allow(_donorContributions[msg.sender], msg.sender);
        emit DonationReceived(msg.sender);
    }

    function addMatchingPool(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _matchingPoolRemaining = FHE.add(_matchingPoolRemaining, amount);
        FHE.allowThis(_matchingPoolRemaining);
        emit MatchingPoolAdded();
    }

    function submitGrant(
        externalEuint64 encAmount, bytes calldata proof,
        string calldata purpose
    ) external returns (uint256 id) {
        require(isVettedNonprofit[msg.sender], "Not vetted nonprofit");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        id = grantCount++;
        grants[id] = Grant({
            recipient: msg.sender, purpose: purpose, requestedAmount: amount,
            approvedAmount: FHE.asEuint64(0), matchedAmount: FHE.asEuint64(0),
            approved: false, disbursed: false, submittedAt: block.timestamp
        });
        FHE.allowThis(grants[id].requestedAmount);
        FHE.allow(grants[id].requestedAmount, msg.sender);
        FHE.allowThis(grants[id].approvedAmount);
        FHE.allow(grants[id].approvedAmount, msg.sender);
        FHE.allowThis(grants[id].matchedAmount);
        emit GrantSubmitted(id, msg.sender);
    }

    function reviewGrant(uint256 grantId, externalEuint64 encApproved, bytes calldata proof) external {
        require(isGrantReviewer[msg.sender], "Not reviewer");
        Grant storage g = grants[grantId];
        require(!g.approved, "Already reviewed");
        euint64 approved = FHE.fromExternal(encApproved, proof);
        // Cap to endowment annual payout
        euint64 annualPayout = FHE.div(FHE.mul(_endowmentBalance, _annualPayoutBps), 10000);
        ebool withinBudget = FHE.le(approved, annualPayout);
        g.approvedAmount = FHE.select(withinBudget, approved, annualPayout);
        // Matching: up to approved amount from matching pool
        ebool hasMatching = FHE.ge(_matchingPoolRemaining, g.approvedAmount);
        euint64 matchAmt = FHE.select(hasMatching, g.approvedAmount, _matchingPoolRemaining);
        g.matchedAmount = matchAmt;
        _matchingPoolRemaining = FHE.sub(_matchingPoolRemaining, matchAmt);
        g.approved = true;
        FHE.allowThis(g.approvedAmount);
        FHE.allow(g.approvedAmount, g.recipient);
        FHE.allowThis(g.matchedAmount);
        FHE.allow(g.matchedAmount, g.recipient);
        FHE.allowThis(_matchingPoolRemaining);
        emit GrantApproved(grantId);
    }

    function disburseGrant(uint256 grantId) external nonReentrant {
        require(isGrantReviewer[msg.sender], "Not reviewer");
        Grant storage g = grants[grantId];
        require(g.approved && !g.disbursed, "Invalid");
        g.disbursed = true;
        euint64 totalDisbursement = FHE.add(g.approvedAmount, g.matchedAmount);
        _endowmentBalance = FHE.sub(_endowmentBalance, totalDisbursement);
        FHE.allowThis(_endowmentBalance);
        FHE.allow(totalDisbursement, g.recipient);
        emit GrantDisbursed(grantId, g.recipient);
    }

    function allowEndowmentStats(address viewer) external onlyOwner {
        FHE.allow(_endowmentBalance, viewer);
        FHE.allow(_matchingPoolRemaining, viewer);
    }

    function allowDonorData(address donor, address viewer) external {
        require(isGrantReviewer[msg.sender] || msg.sender == donor, "Unauthorized");
        FHE.allow(_donorContributions[donor], viewer);
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