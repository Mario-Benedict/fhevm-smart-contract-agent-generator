// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePrivateEquitySecondaryMarket
/// @notice Encrypted LP interest secondary market: hidden NAV per share, confidential
///         transfer pricing, private capital account balances, and encrypted distribution
///         waterfalls for GP/LP profit splits.
contract PrivatePrivateEquitySecondaryMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FundVintage { V2019, V2020, V2021, V2022, V2023, V2024 }
    enum TransferStatus { Offered, Matched, Completed, Cancelled }

    struct LPInterest {
        address lpHolder;
        uint256 fundId;
        FundVintage vintage;
        euint64 committedCapitalUSD;   // encrypted committed capital
        euint64 calledCapitalUSD;      // encrypted capital called
        euint64 navUSD;                // encrypted current NAV
        euint64 distributionsReceivedUSD; // encrypted distributions
        euint32 lpSharesBps;           // encrypted LP share of fund in bps
        bool transferable;
    }

    struct SecondaryOffer {
        uint256 lpInterestId;
        address seller;
        euint64 askPriceUSD;           // encrypted asking price
        euint64 discountToPar;         // encrypted discount to NAV bps
        address buyer;
        euint64 agreedPriceUSD;        // encrypted agreed price
        TransferStatus status;
        uint256 offeredAt;
    }

    mapping(uint256 => LPInterest) private lpInterests;
    mapping(uint256 => SecondaryOffer) private secondaryOffers;
    mapping(address => bool) public isPlacementAgent;

    uint256 public lpInterestCount;
    uint256 public offerCount;
    euint64 private _totalSecondaryVolumeUSD;
    euint64 private _totalNavOnPlatformUSD;

    event LPInterestRegistered(uint256 indexed id, FundVintage vintage);
    event SecondaryOfferCreated(uint256 indexed offerId, uint256 lpInterestId);
    event SecondaryTransferCompleted(uint256 indexed offerId, address buyer);

    modifier onlyPlacementAgent() {
        require(isPlacementAgent[msg.sender] || msg.sender == owner(), "Not placement agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSecondaryVolumeUSD = FHE.asEuint64(0);
        _totalNavOnPlatformUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSecondaryVolumeUSD);
        FHE.allowThis(_totalNavOnPlatformUSD);
        isPlacementAgent[msg.sender] = true;
    }

    function addPlacementAgent(address a) external onlyOwner { isPlacementAgent[a] = true; }

    function registerLPInterest(
        uint256 fundId,
        FundVintage vintage,
        externalEuint64 encCommitted, bytes calldata cProof,
        externalEuint64 encCalled, bytes calldata calProof,
        externalEuint64 encNAV, bytes calldata navProof,
        externalEuint32 encSharesBps, bytes calldata sProof
    ) external returns (uint256 id) {
        euint64 committed = FHE.fromExternal(encCommitted, cProof);
        euint64 called = FHE.fromExternal(encCalled, calProof);
        euint64 nav = FHE.fromExternal(encNAV, navProof);
        euint32 sharesBps = FHE.fromExternal(encSharesBps, sProof);
        id = lpInterestCount++;
        lpInterests[id].lpHolder = msg.sender;
        lpInterests[id].fundId = fundId;
        lpInterests[id].vintage = vintage;
        lpInterests[id].committedCapitalUSD = committed;
        lpInterests[id].calledCapitalUSD = called;
        lpInterests[id].navUSD = nav;
        lpInterests[id].distributionsReceivedUSD = FHE.asEuint64(0);
        lpInterests[id].lpSharesBps = sharesBps;
        lpInterests[id].transferable = true;
        _totalNavOnPlatformUSD = FHE.add(_totalNavOnPlatformUSD, nav);
        FHE.allowThis(lpInterests[id].committedCapitalUSD); FHE.allow(lpInterests[id].committedCapitalUSD, msg.sender);
        FHE.allowThis(lpInterests[id].calledCapitalUSD); FHE.allow(lpInterests[id].calledCapitalUSD, msg.sender);
        FHE.allowThis(lpInterests[id].navUSD); FHE.allow(lpInterests[id].navUSD, msg.sender);
        FHE.allowThis(lpInterests[id].distributionsReceivedUSD); FHE.allow(lpInterests[id].distributionsReceivedUSD, msg.sender);
        FHE.allowThis(lpInterests[id].lpSharesBps); FHE.allow(lpInterests[id].lpSharesBps, msg.sender);
        FHE.allowThis(_totalNavOnPlatformUSD);
        emit LPInterestRegistered(id, vintage);
    }

    function createSecondaryOffer(
        uint256 lpInterestId,
        externalEuint64 encAskPrice, bytes calldata apProof,
        externalEuint64 encDiscount, bytes calldata dProof
    ) external returns (uint256 offerId) {
        LPInterest storage lp = lpInterests[lpInterestId];
        require(msg.sender == lp.lpHolder && lp.transferable, "Not authorized");
        euint64 askPrice = FHE.fromExternal(encAskPrice, apProof);
        euint64 discount = FHE.fromExternal(encDiscount, dProof);
        offerId = offerCount++;
        secondaryOffers[offerId] = SecondaryOffer({
            lpInterestId: lpInterestId, seller: msg.sender, askPriceUSD: askPrice,
            discountToPar: discount, buyer: address(0), agreedPriceUSD: FHE.asEuint64(0),
            status: TransferStatus.Offered, offeredAt: block.timestamp
        });
        FHE.allowThis(secondaryOffers[offerId].askPriceUSD); FHE.allow(secondaryOffers[offerId].askPriceUSD, msg.sender);
        FHE.allowThis(secondaryOffers[offerId].discountToPar);
        FHE.allowThis(secondaryOffers[offerId].agreedPriceUSD);
        emit SecondaryOfferCreated(offerId, lpInterestId);
    }

    function matchSecondaryOffer(
        uint256 offerId,
        address buyer,
        externalEuint64 encAgreedPrice, bytes calldata proof
    ) external onlyPlacementAgent nonReentrant {
        SecondaryOffer storage so = secondaryOffers[offerId];
        require(so.status == TransferStatus.Offered, "Not offered");
        euint64 agreedPrice = FHE.fromExternal(encAgreedPrice, proof);
        so.buyer = buyer;
        so.agreedPriceUSD = agreedPrice;
        so.status = TransferStatus.Completed;
        LPInterest storage lp = lpInterests[so.lpInterestId];
        lp.lpHolder = buyer;
        _totalSecondaryVolumeUSD = FHE.add(_totalSecondaryVolumeUSD, agreedPrice);
        FHE.allowThis(so.agreedPriceUSD); FHE.allow(so.agreedPriceUSD, so.seller); FHE.allow(so.agreedPriceUSD, buyer);
        FHE.allowThis(_totalSecondaryVolumeUSD);
        FHE.allow(lp.navUSD, buyer); // [acl_misconfig]
        FHE.allow(_totalSecondaryVolumeUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalNavOnPlatformUSD, msg.sender); // [acl_misconfig]
        FHE.allow(lp.committedCapitalUSD, buyer);
        emit SecondaryTransferCompleted(offerId, buyer);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalSecondaryVolumeUSD, viewer);
        FHE.allow(_totalNavOnPlatformUSD, viewer);
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