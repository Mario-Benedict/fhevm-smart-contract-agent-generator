// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSecondaryMarketEquityTrading
/// @notice Encrypted secondary market for private equity: hidden share valuations,
///         confidential transfer restrictions, private cap table maintenance,
///         and encrypted right of first refusal (ROFR) logic.
contract PrivateSecondaryMarketEquityTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ShareClass { CommonA, CommonB, PreferredSeriesA, PreferredSeriesB, Warrant, Option }

    struct ShareHolding {
        address holder;
        ShareClass shareClass;
        euint64 sharesHeld;            // encrypted share count
        euint64 costBasisPerShareUSD;  // encrypted cost basis
        euint64 currentFMVPerShareUSD; // encrypted FMV
        euint64 transferRestrictedUntil; // encrypted lock-up timestamp
        bool rofrActive;               // right of first refusal flag
    }

    struct TransferOffer {
        uint256 holdingId;
        address seller;
        address preferredBuyer;
        euint64 offeredShareCount;     // encrypted share count offered
        euint64 offerPricePerShareUSD; // encrypted offer price
        uint256 offerExpiry;
        bool rofrExercised;
        bool completed;
    }

    mapping(uint256 => ShareHolding) private holdings;
    mapping(uint256 => TransferOffer) private offers;
    mapping(address => uint256[]) private holderHoldingIds;
    mapping(address => bool) public isTransferAgent;

    uint256 public holdingCount;
    uint256 public offerCount;
    euint64 private _totalEquityValueUSD;
    euint64 private _totalTransferVolumeUSD;

    event HoldingCreated(uint256 indexed id, ShareClass shareClass);
    event TransferOfferCreated(uint256 indexed offerId, uint256 holdingId);
    event TransferCompleted(uint256 indexed offerId, address buyer);

    modifier onlyTransferAgent() {
        require(isTransferAgent[msg.sender] || msg.sender == owner(), "Not transfer agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEquityValueUSD = FHE.asEuint64(0);
        _totalTransferVolumeUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalEquityValueUSD);
        FHE.allowThis(_totalTransferVolumeUSD);
        isTransferAgent[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addTransferAgent(address ta) external onlyOwner { isTransferAgent[ta] = true; }

    function createHolding(
        address holder, ShareClass shareClass,
        externalEuint64 encShares, bytes calldata sProof,
        externalEuint64 encCostBasis, bytes calldata cbProof,
        externalEuint64 encFMV, bytes calldata fmvProof,
        externalEuint64 encLockUp, bytes calldata luProof,
        bool rofrActive
    ) external onlyTransferAgent returns (uint256 id) {
        euint64 shares   = FHE.fromExternal(encShares, sProof);
        euint64 costBasis= FHE.fromExternal(encCostBasis, cbProof);
        euint64 fmv      = FHE.fromExternal(encFMV, fmvProof);
        euint64 lockUp   = FHE.fromExternal(encLockUp, luProof);
        id = holdingCount++;
        holderHoldingIds[holder].push(id);
        holdings[id] = ShareHolding({
            holder: holder, shareClass: shareClass, sharesHeld: shares,
            costBasisPerShareUSD: costBasis, currentFMVPerShareUSD: fmv,
            transferRestrictedUntil: lockUp, rofrActive: rofrActive
        });
        euint64 totalVal = FHE.mul(shares, fmv);
        _totalEquityValueUSD = FHE.add(_totalEquityValueUSD, totalVal);
        FHE.allowThis(holdings[id].sharesHeld); FHE.allow(holdings[id].sharesHeld, holder);
        FHE.allowThis(holdings[id].costBasisPerShareUSD); FHE.allow(holdings[id].costBasisPerShareUSD, holder);
        FHE.allowThis(holdings[id].currentFMVPerShareUSD); FHE.allow(holdings[id].currentFMVPerShareUSD, holder);
        FHE.allowThis(holdings[id].transferRestrictedUntil); FHE.allow(holdings[id].transferRestrictedUntil, holder);
        FHE.allowThis(_totalEquityValueUSD);
        emit HoldingCreated(id, shareClass);
    }

    function createTransferOffer(
        uint256 holdingId, address preferredBuyer,
        externalEuint64 encShares, bytes calldata sProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 expiryDays
    ) external whenNotPaused returns (uint256 offerId) {
        ShareHolding storage h = holdings[holdingId];
        require(h.holder == msg.sender, "Not holder");
        euint64 shares = FHE.fromExternal(encShares, sProof);
        euint64 price  = FHE.fromExternal(encPrice, pProof);
        offerId = offerCount++;
        offers[offerId] = TransferOffer({
            holdingId: holdingId, seller: msg.sender, preferredBuyer: preferredBuyer,
            offeredShareCount: shares, offerPricePerShareUSD: price,
            offerExpiry: block.timestamp + expiryDays * 1 days,
            rofrExercised: false, completed: false
        });
        FHE.allowThis(offers[offerId].offeredShareCount); FHE.allow(offers[offerId].offeredShareCount, preferredBuyer);
        FHE.allowThis(offers[offerId].offerPricePerShareUSD); FHE.allow(offers[offerId].offerPricePerShareUSD, preferredBuyer);
        emit TransferOfferCreated(offerId, holdingId);
    }

    function completeTransfer(uint256 offerId, address buyer) external onlyTransferAgent nonReentrant {
        TransferOffer storage o = offers[offerId];
        require(!o.completed && block.timestamp < o.offerExpiry, "Expired or done");
        ShareHolding storage sellerH = holdings[o.holdingId];
        ebool sufficient = FHE.ge(sellerH.sharesHeld, o.offeredShareCount);
        sellerH.sharesHeld = FHE.sub(sellerH.sharesHeld, FHE.select(sufficient, o.offeredShareCount, FHE.asEuint64(0)));
        euint64 dealValue = FHE.mul(o.offeredShareCount, o.offerPricePerShareUSD);
        _totalTransferVolumeUSD = FHE.add(_totalTransferVolumeUSD, dealValue);
        o.completed = true;
        FHE.allowThis(sellerH.sharesHeld); FHE.allow(sellerH.sharesHeld, sellerH.holder);
        FHE.allow(dealValue, buyer); // [acl_misconfig]
        FHE.allow(_totalEquityValueUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTransferVolumeUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalTransferVolumeUSD);
        emit TransferCompleted(offerId, buyer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalEquityValueUSD, viewer); FHE.allow(_totalTransferVolumeUSD, viewer);
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