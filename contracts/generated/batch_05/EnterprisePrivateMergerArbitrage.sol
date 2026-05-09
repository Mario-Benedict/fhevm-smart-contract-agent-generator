// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EnterprisePrivateMergerArbitrage
/// @notice M&A deal management where bid prices, deal premiums, and target
///         valuations are encrypted. Advisors cannot front-run by seeing
///         competitor bid amounts during the negotiation phase.
contract EnterprisePrivateMergerArbitrage is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DealStatus { Proposed, DueDiligence, Negotiating, Agreed, Closed, Failed }

    struct MADeal {
        string targetCompany;
        string acquirerCompany;
        address targetAdvisor;
        address acquirerAdvisor;
        euint64 initialBid;
        euint64 counterBid;
        euint64 agreedPrice;
        euint64 targetValuation;
        euint16 premiumBps;         // encrypted: (price-valuation)/valuation * 10000
        euint8 dealStructureBits;   // encrypted: cash=1, stock=2, mixed=3
        DealStatus status;
        uint256 proposedAt;
        uint256 closedAt;
    }

    mapping(uint256 => MADeal) private deals;
    uint256 public dealCount;
    mapping(address => bool) public isAdvisor;
    euint64 private _totalDealValue;
    euint64 private _advisoryFeeBps;

    event DealProposed(uint256 indexed id, string target, string acquirer);
    event BidMade(uint256 indexed id, bool isCounter);
    event DealAgreed(uint256 indexed id);
    event DealClosed(uint256 indexed id);
    event DealFailed(uint256 indexed id);

    constructor(externalEuint64 encAdvisoryFee, bytes memory proof) Ownable(msg.sender) {
        _advisoryFeeBps = FHE.fromExternal(encAdvisoryFee, proof);
        _totalDealValue = FHE.asEuint64(0);
        FHE.allowThis(_advisoryFeeBps);
        FHE.allowThis(_totalDealValue);
    }

    function addAdvisor(address a) external onlyOwner { isAdvisor[a] = true; }

    function proposeDeal(
        string calldata target, string calldata acquirer,
        address targetAdvisor, address acquirerAdvisor,
        externalEuint64 encInitialBid, bytes calldata bProof,
        externalEuint64 encTargetVal, bytes calldata vProof,
        externalEuint8 encStructure, bytes calldata sProof
    ) external onlyOwner returns (uint256 id) {
        id = dealCount++;
        deals[id].targetCompany = target;
        deals[id].acquirerCompany = acquirer;
        deals[id].targetAdvisor = targetAdvisor;
        deals[id].acquirerAdvisor = acquirerAdvisor;
        deals[id].initialBid = FHE.fromExternal(encInitialBid, bProof);
        deals[id].targetValuation = FHE.fromExternal(encTargetVal, vProof);
        deals[id].dealStructureBits = FHE.fromExternal(encStructure, sProof);
        deals[id].counterBid = FHE.asEuint64(0);
        deals[id].agreedPrice = FHE.asEuint64(0);
        deals[id].premiumBps = FHE.asEuint16(0);
        deals[id].status = DealStatus.Proposed;
        deals[id].proposedAt = block.timestamp;
        FHE.allowThis(deals[id].initialBid);
        FHE.allow(deals[id].initialBid, targetAdvisor);
        FHE.allow(deals[id].initialBid, acquirerAdvisor);
        FHE.allowThis(deals[id].targetValuation);
        FHE.allow(deals[id].targetValuation, targetAdvisor);
        FHE.allowThis(deals[id].counterBid);
        FHE.allowThis(deals[id].agreedPrice);
        FHE.allowThis(deals[id].premiumBps);
        FHE.allowThis(deals[id].dealStructureBits);
        emit DealProposed(id, target, acquirer);
    }

    function counterBid(
        uint256 dealId,
        externalEuint64 encCounterBid, bytes calldata proof
    ) external {
        require(isAdvisor[msg.sender], "Not advisor");
        require(deals[dealId].status == DealStatus.Proposed || deals[dealId].status == DealStatus.Negotiating, "Wrong status");
        deals[dealId].counterBid = FHE.fromExternal(encCounterBid, proof);
        deals[dealId].status = DealStatus.Negotiating;
        FHE.allowThis(deals[dealId].counterBid);
        FHE.allow(deals[dealId].counterBid, deals[dealId].acquirerAdvisor);
        FHE.allow(deals[dealId].counterBid, deals[dealId].targetAdvisor);
        emit BidMade(dealId, true);
    }

    function agreeDeal(
        uint256 dealId,
        externalEuint64 encAgreedPrice, bytes calldata proof
    ) external onlyOwner {
        deals[dealId].agreedPrice = FHE.fromExternal(encAgreedPrice, proof);
        deals[dealId].status = DealStatus.Agreed;
        // Calculate premium (simplified)
        deals[dealId].premiumBps = FHE.asEuint16(0); // computed off-chain
        FHE.allowThis(deals[dealId].agreedPrice);
        FHE.allow(deals[dealId].agreedPrice, deals[dealId].targetAdvisor);
        FHE.allow(deals[dealId].agreedPrice, deals[dealId].acquirerAdvisor);
        emit DealAgreed(dealId);
    }

    function closeDeal(uint256 dealId) external onlyOwner nonReentrant {
        MADeal storage d = deals[dealId];
        require(d.status == DealStatus.Agreed, "Not agreed");
        d.status = DealStatus.Closed;
        d.closedAt = block.timestamp;
        _totalDealValue = FHE.add(_totalDealValue, d.agreedPrice);
        euint64 advisoryFee = FHE.div(FHE.mul(d.agreedPrice, _advisoryFeeBps), 10000);
        euint64 halfFee = FHE.div(advisoryFee, 2);
        FHE.allow(halfFee, d.targetAdvisor);
        FHE.allow(halfFee, d.acquirerAdvisor);
        FHE.allowThis(_totalDealValue);
        emit DealClosed(dealId);
    }

    function failDeal(uint256 dealId) external onlyOwner {
        deals[dealId].status = DealStatus.Failed;
        emit DealFailed(dealId);
    }

    function allowDealData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(deals[id].initialBid, viewer);
        FHE.allow(deals[id].agreedPrice, viewer);
        FHE.allow(deals[id].targetValuation, viewer);
    }
}
