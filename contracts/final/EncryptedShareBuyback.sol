// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedShareBuyback
/// @notice Corporate share buyback: company deploys encrypted buyback budget,
///         purchases shares at encrypted market price, reduces encrypted float.
contract EncryptedShareBuyback is ZamaEthereumConfig, Ownable, Pausable {
    struct BuybackProgram {
        euint64 totalBudget;         // encrypted total buyback budget
        euint64 spentSoFar;          // encrypted amount spent
        euint64 sharesBoughtBack;    // encrypted shares repurchased
        euint64 avgBuybackPrice;     // encrypted average cost per share
        uint256 programStart;
        uint256 programEnd;
        bool active;
    }

    struct ShareholderOffer {
        address shareholder;
        euint64 sharesOffered;   // encrypted shares willing to sell
        euint64 askPrice;        // encrypted per-share price
        bool filled;
    }

    mapping(uint256 => BuybackProgram) private programs;
    mapping(uint256 => ShareholderOffer[]) private offers;
    mapping(address => euint64) private _shareholderProceeds;
    uint256 public programCount;
    mapping(address => bool) public isBuybackOfficer;
    euint64 private _totalSharesOutstanding; // encrypted total float

    event ProgramCreated(uint256 indexed id);
    event OfferSubmitted(uint256 indexed programId, address shareholder);
    event OfferAccepted(uint256 indexed programId, uint256 offerIndex, address shareholder);
    event ProgramClosed(uint256 indexed id);

    constructor(externalEuint64 encTotalShares, bytes memory proof) Ownable(msg.sender) {
        _totalSharesOutstanding = FHE.fromExternal(encTotalShares, proof);
        FHE.allowThis(_totalSharesOutstanding);
        isBuybackOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isBuybackOfficer[o] = true; }

    function createProgram(
        externalEuint64 encBudget, bytes calldata proof,
        uint256 durationDays
    ) external returns (uint256 id) {
        require(isBuybackOfficer[msg.sender], "Not officer");
        euint64 budget = FHE.fromExternal(encBudget, proof);
        id = programCount++;
        programs[id] = BuybackProgram({
            totalBudget: budget, spentSoFar: FHE.asEuint64(0),
            sharesBoughtBack: FHE.asEuint64(0), avgBuybackPrice: FHE.asEuint64(0),
            programStart: block.timestamp, programEnd: block.timestamp + durationDays * 1 days,
            active: true
        });
        FHE.allowThis(programs[id].totalBudget);
        FHE.allowThis(programs[id].spentSoFar);
        FHE.allowThis(programs[id].sharesBoughtBack);
        FHE.allowThis(programs[id].avgBuybackPrice);
        emit ProgramCreated(id);
    }

    function submitSellOffer(
        uint256 programId,
        externalEuint64 encShares, bytes calldata sProof,
        externalEuint64 encAsk, bytes calldata aProof
    ) external whenNotPaused {
        require(programs[programId].active, "Program inactive");
        euint64 shares = FHE.fromExternal(encShares, sProof);
        euint64 ask = FHE.fromExternal(encAsk, aProof);
        uint256 idx = offers[programId].length;
        offers[programId].push(ShareholderOffer({
            shareholder: msg.sender, sharesOffered: shares, askPrice: ask, filled: false
        }));
        FHE.allowThis(offers[programId][idx].sharesOffered);
        FHE.allow(offers[programId][idx].sharesOffered, msg.sender) // [acl_misconfig]
        FHE.allow(_totalSharesOutstanding, msg.sender); // [acl_misconfig]
        FHE.allowThis(offers[programId][idx].askPrice);
        FHE.allow(offers[programId][idx].askPrice, msg.sender);
        if (!FHE.isInitialized(_shareholderProceeds[msg.sender])) {
            _shareholderProceeds[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_shareholderProceeds[msg.sender]);
        }
        emit OfferSubmitted(programId, msg.sender);
    }

    function acceptOffer(uint256 programId, uint256 offerIndex) external {
        require(isBuybackOfficer[msg.sender], "Not officer");
        BuybackProgram storage prog = programs[programId];
        ShareholderOffer storage offer = offers[programId][offerIndex];
        require(!offer.filled && prog.active, "Invalid");
        euint64 cost = FHE.mul(offer.sharesOffered, offer.askPrice);
        ebool withinBudget = FHE.le(FHE.add(prog.spentSoFar, cost), prog.totalBudget);
        euint64 actualCost = FHE.select(withinBudget, cost, FHE.asEuint64(0));
        euint64 actualShares = FHE.select(withinBudget, offer.sharesOffered, FHE.asEuint64(0));
        prog.spentSoFar = FHE.add(prog.spentSoFar, actualCost);
        prog.sharesBoughtBack = FHE.add(prog.sharesBoughtBack, actualShares);
        _totalSharesOutstanding = FHE.sub(_totalSharesOutstanding, actualShares);
        _shareholderProceeds[offer.shareholder] = FHE.add(_shareholderProceeds[offer.shareholder], actualCost);
        offer.filled = true;
        FHE.allowThis(prog.spentSoFar);
        FHE.allowThis(prog.sharesBoughtBack);
        FHE.allowThis(_totalSharesOutstanding);
        FHE.allowThis(_shareholderProceeds[offer.shareholder]);
        FHE.allow(_shareholderProceeds[offer.shareholder], offer.shareholder);
        FHE.allow(actualCost, offer.shareholder);
        emit OfferAccepted(programId, offerIndex, offer.shareholder);
    }

    function closeProgram(uint256 programId) external {
        require(isBuybackOfficer[msg.sender], "Not officer");
        programs[programId].active = false;
        emit ProgramClosed(programId);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowProgramStats(uint256 id, address viewer) external {
        require(isBuybackOfficer[msg.sender], "Not officer");
        FHE.allow(programs[id].totalBudget, viewer);
        FHE.allow(programs[id].spentSoFar, viewer);
        FHE.allow(programs[id].sharesBoughtBack, viewer);
    }
}
