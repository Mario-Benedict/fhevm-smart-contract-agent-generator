// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCarbonCreditForwardDelivery
/// @notice Encrypted carbon credit forward delivery contracts: hidden delivery volumes,
///         confidential forward prices, private counterparty exposure limits, and
///         encrypted margin requirements for mark-to-market settlement.
contract PrivateCarbonCreditForwardDelivery is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CreditStandard { VCS, GoldStandard, CDM, ACR, CAR, Plan_Vivo }
    enum ContractStatus { Open, Matched, Active, Delivered, Defaulted, Cancelled }

    struct ForwardOffer {
        address seller;
        CreditStandard standard;
        string projectId;
        euint32 volumeTonnesCO2;       // encrypted volume for delivery
        euint64 forwardPricePerTonne;  // encrypted price per tonne
        euint64 initialMarginUSD;      // encrypted initial margin required
        uint256 deliveryDate;
        ContractStatus status;
    }

    struct ForwardPosition {
        uint256 offerId;
        address buyer;
        euint64 buyerMarginPostedUSD;  // encrypted buyer margin
        euint64 mtmValueUSD;           // encrypted mark-to-market value
        euint64 unrealizedPnLUSD;      // encrypted unrealized PnL
        bool buyerDefault;
        bool sellerDefault;
    }

    mapping(uint256 => ForwardOffer) private offers;
    mapping(uint256 => ForwardPosition) private positions;
    mapping(address => bool) public isRegistry;
    mapping(address => bool) public isClearingAgent;

    uint256 public offerCount;
    uint256 public positionCount;
    euint64 private _totalOpenInterestUSD;
    euint64 private _totalDeliveredValueUSD;

    event OfferCreated(uint256 indexed id, CreditStandard standard, string projectId);
    event PositionOpened(uint256 indexed posId, uint256 offerId, address buyer);
    event MarginCalled(uint256 indexed posId);
    event ForwardDelivered(uint256 indexed posId);

    modifier onlyClearingAgent() {
        require(isClearingAgent[msg.sender] || msg.sender == owner(), "Not clearing agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOpenInterestUSD = FHE.asEuint64(0);
        _totalDeliveredValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allowThis(_totalDeliveredValueUSD);
        isClearingAgent[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addClearingAgent(address a) external onlyOwner { isClearingAgent[a] = true; }
    function addRegistry(address r) external onlyOwner { isRegistry[r] = true; }

    function createForwardOffer(
        CreditStandard standard,
        string calldata projectId,
        externalEuint32 encVolume, bytes calldata vProof,
        externalEuint64 encFwdPrice, bytes calldata fpProof,
        externalEuint64 encMargin, bytes calldata mProof,
        uint256 deliveryDays
    ) external whenNotPaused returns (uint256 id) {
        euint32 vol = FHE.fromExternal(encVolume, vProof);
        euint64 fwdPrice = FHE.fromExternal(encFwdPrice, fpProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        id = offerCount++;
        offers[id] = ForwardOffer({
            seller: msg.sender, standard: standard, projectId: projectId,
            volumeTonnesCO2: vol, forwardPricePerTonne: fwdPrice, initialMarginUSD: margin,
            deliveryDate: block.timestamp + deliveryDays * 1 days, status: ContractStatus.Open
        });
        FHE.allowThis(offers[id].volumeTonnesCO2); FHE.allow(offers[id].volumeTonnesCO2, msg.sender);
        FHE.allowThis(offers[id].forwardPricePerTonne); FHE.allow(offers[id].forwardPricePerTonne, msg.sender);
        FHE.allowThis(offers[id].initialMarginUSD); FHE.allow(offers[id].initialMarginUSD, msg.sender);
        emit OfferCreated(id, standard, projectId);
    }

    function openPosition(
        uint256 offerId,
        externalEuint64 encBuyerMargin, bytes calldata proof
    ) external whenNotPaused nonReentrant returns (uint256 posId) {
        ForwardOffer storage o = offers[offerId];
        require(o.status == ContractStatus.Open, "Not open");
        euint64 buyerMargin = FHE.fromExternal(encBuyerMargin, proof);
        ebool marginSufficient = FHE.ge(buyerMargin, o.initialMarginUSD);
        euint64 postedMargin = FHE.select(marginSufficient, buyerMargin, FHE.asEuint64(0));
        o.status = ContractStatus.Active;
        posId = positionCount++;
        positions[posId] = ForwardPosition({
            offerId: offerId, buyer: msg.sender, buyerMarginPostedUSD: postedMargin,
            mtmValueUSD: FHE.asEuint64(0), unrealizedPnLUSD: FHE.asEuint64(0),
            buyerDefault: false, sellerDefault: false
        });
        euint64 contractValue = FHE.mul(FHE.asEuint64(uint64(1)), o.forwardPricePerTonne); // 1 unit proxy
        _totalOpenInterestUSD = FHE.add(_totalOpenInterestUSD, contractValue);
        FHE.allowThis(positions[posId].buyerMarginPostedUSD); FHE.allow(positions[posId].buyerMarginPostedUSD, msg.sender); FHE.allow(positions[posId].buyerMarginPostedUSD, o.seller);
        FHE.allowThis(positions[posId].mtmValueUSD);
        FHE.allowThis(positions[posId].unrealizedPnLUSD); FHE.allow(positions[posId].unrealizedPnLUSD, msg.sender);
        FHE.allowThis(_totalOpenInterestUSD);
        emit PositionOpened(posId, offerId, msg.sender);
    }

    function updateMTM(
        uint256 posId,
        externalEuint64 encMTM, bytes calldata mtmProof,
        externalEuint64 encPnL, bytes calldata pnlProof
    ) external onlyClearingAgent {
        ForwardPosition storage p = positions[posId];
        ForwardOffer storage o = offers[p.offerId];
        p.mtmValueUSD = FHE.fromExternal(encMTM, mtmProof);
        p.unrealizedPnLUSD = FHE.fromExternal(encPnL, pnlProof);
        // Check margin call: if PnL deeply negative vs margin
        ebool marginBreached = FHE.gt(p.mtmValueUSD, p.buyerMarginPostedUSD);
        FHE.allowThis(p.mtmValueUSD); FHE.allow(p.mtmValueUSD, p.buyer); FHE.allow(p.mtmValueUSD, o.seller);
        FHE.allowThis(p.unrealizedPnLUSD); FHE.allow(p.unrealizedPnLUSD, p.buyer);
        FHE.allowThis(marginBreached);
        if (FHE.isInitialized(marginBreached)) emit MarginCalled(posId);
    }

    function settleDelivery(uint256 posId) external onlyClearingAgent nonReentrant {
        ForwardPosition storage p = positions[posId];
        ForwardOffer storage o = offers[p.offerId];
        require(block.timestamp >= o.deliveryDate, "Not delivery date");
        o.status = ContractStatus.Delivered;
        euint64 deliveryValue = FHE.mul(FHE.asEuint64(1), o.forwardPricePerTonne);
        _totalDeliveredValueUSD = FHE.add(_totalDeliveredValueUSD, deliveryValue);
        _totalOpenInterestUSD = FHE.sub(_totalOpenInterestUSD, deliveryValue);
        FHE.allowThis(_totalDeliveredValueUSD);
        FHE.allowThis(_totalOpenInterestUSD);
        FHE.allow(o.forwardPricePerTonne, p.buyer);
        emit ForwardDelivered(posId);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalOpenInterestUSD, viewer);
        FHE.allow(_totalDeliveredValueUSD, viewer);
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