// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCrossChainForexSettlement
/// @notice Multi-currency FX settlement with encrypted exchange rates,
///         confidential bilateral netting, and private PvP (payment-versus-payment) settlement.
///         Designed for interbank FX and corporate treasury FX transactions.
contract EncryptedCrossChainForexSettlement is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    enum Currency { USD, EUR, GBP, JPY, CHF, CNY, AUD, CAD }
    enum SettlementType { PVP, FREE_OF_PAYMENT, GROSS, NETTED }

    struct FXRate {
        euint64 bidRateBps;       // encrypted bid rate (base currency units * 1e6)
        euint64 askRateBps;       // encrypted ask rate
        euint64 midRateBps;       // encrypted mid rate
        euint64 spreadBps;        // encrypted bid-ask spread
        uint256 lastUpdated;
        bool active;
    }

    struct FXTransaction {
        address buyer;
        address seller;
        Currency buyCurrency;
        Currency sellCurrency;
        euint64 buyAmountUnits;       // encrypted amount to receive
        euint64 sellAmountUnits;      // encrypted amount to deliver
        euint64 agreedRateBps;        // encrypted agreed exchange rate
        euint64 fxGainLossUSD;        // encrypted realised gain/loss
        SettlementType settlementType;
        uint256 valueDate;
        bool buyerConfirmed;
        bool sellerConfirmed;
        bool settled;
    }

    struct PartyBalance {
        mapping(uint8 => euint64) currencyBalances; // Currency => balance
        euint64 totalExposureUSD;    // encrypted total open FX exposure
        euint64 dailyVolumeUSD;      // encrypted daily transaction volume
        euint64 creditLimitUSD;      // encrypted bilateral credit limit
        bool approved;
    }

    struct NettingPosition {
        mapping(uint8 => euint64) netPositionByCurrency; // net per currency pair
        euint64 totalNetObligationUSD;
        bool computed;
    }

    mapping(bytes4 => FXRate) private fxRates; // currencyPair code
    mapping(uint256 => FXTransaction) private transactions;
    mapping(address => PartyBalance) private partyBalances;
    mapping(bytes32 => NettingPosition) private nettingPositions; // keccak(partyA, partyB)
    mapping(address => bool) public isFXDealer;
    mapping(address => bool) public isSettlementAgent;

    uint256 public txCount;
    euint64 private _systemDailyFXVolume;
    euint64 private _systemNettingSavings;

    event FXRatePublished(bytes4 currencyPair, uint256 timestamp);
    event TransactionBooked(uint256 indexed txId, address buyer, address seller);
    event TransactionConfirmed(uint256 indexed txId, address confirmer);
    event TransactionSettled(uint256 indexed txId);
    event NettingProcessed(address indexed partyA, address indexed partyB);

    constructor() Ownable(msg.sender) {
        _systemDailyFXVolume = FHE.asEuint64(0);
        _systemNettingSavings = FHE.asEuint64(0);
        FHE.allowThis(_systemDailyFXVolume);
        FHE.allowThis(_systemNettingSavings);
        isFXDealer[msg.sender] = true;
        isSettlementAgent[msg.sender] = true;
    }

    modifier onlyFXDealer() { require(isFXDealer[msg.sender], "Not FX dealer"); _; }
    modifier onlySettlementAgent() { require(isSettlementAgent[msg.sender], "Not settlement agent"); _; }

    function publishFXRate(
        bytes4 currencyPair,
        externalEuint64 encBid, bytes calldata bidProof,
        externalEuint64 encAsk, bytes calldata askProof,
        externalEuint64 encMid, bytes calldata midProof
    ) external onlyFXDealer {
        FXRate storage rate = fxRates[currencyPair];
        rate.bidRateBps = FHE.fromExternal(encBid, bidProof);
        rate.askRateBps = FHE.fromExternal(encAsk, askProof);
        rate.midRateBps = FHE.fromExternal(encMid, midProof);
        ebool _safeSub191 = FHE.ge(rate.askRateBps, rate.bidRateBps);
        rate.spreadBps = FHE.select(_safeSub191, FHE.sub(rate.askRateBps, rate.bidRateBps), FHE.asEuint64(0));
        rate.lastUpdated = block.timestamp;
        rate.active = true;
        FHE.allowThis(rate.bidRateBps);
        FHE.allowThis(rate.askRateBps);
        FHE.allowThis(rate.midRateBps);
        FHE.allowThis(rate.spreadBps);
        emit FXRatePublished(currencyPair, block.timestamp);
    }

    function bookTransaction(
        address seller,
        Currency buyCurrency,
        Currency sellCurrency,
        externalEuint64 encBuyAmount, bytes calldata baProof,
        externalEuint64 encSellAmount, bytes calldata saProof,
        externalEuint64 encAgreedRate, bytes calldata arProof,
        SettlementType settlementType,
        uint256 valueDate
    ) external nonReentrant whenNotPaused returns (uint256 txId) {
        require(partyBalances[msg.sender].approved && partyBalances[seller].approved, "Parties not approved");
        euint64 buyAmt = FHE.fromExternal(encBuyAmount, baProof);
        euint64 sellAmt = FHE.fromExternal(encSellAmount, saProof);
        euint64 agreedRate = FHE.fromExternal(encAgreedRate, arProof);
        txId = txCount++;
        FXTransaction storage fxt = transactions[txId];
        fxt.buyer = msg.sender;
        fxt.seller = seller;
        fxt.buyCurrency = buyCurrency;
        fxt.sellCurrency = sellCurrency;
        fxt.buyAmountUnits = buyAmt;
        fxt.sellAmountUnits = sellAmt;
        fxt.agreedRateBps = agreedRate;
        fxt.fxGainLossUSD = FHE.asEuint64(0);
        fxt.settlementType = settlementType;
        fxt.valueDate = valueDate;
        // Update exposures
        partyBalances[msg.sender].totalExposureUSD = FHE.add(partyBalances[msg.sender].totalExposureUSD, sellAmt);
        partyBalances[msg.sender].dailyVolumeUSD = FHE.add(partyBalances[msg.sender].dailyVolumeUSD, sellAmt);
        FHE.allowThis(fxt.buyAmountUnits);
        FHE.allow(fxt.buyAmountUnits, msg.sender);
        FHE.allow(fxt.buyAmountUnits, seller);
        FHE.allowThis(fxt.sellAmountUnits);
        FHE.allow(fxt.sellAmountUnits, msg.sender);
        FHE.allow(fxt.sellAmountUnits, seller);
        FHE.allowThis(fxt.agreedRateBps);
        FHE.allow(fxt.agreedRateBps, msg.sender);
        FHE.allow(fxt.agreedRateBps, seller);
        FHE.allowThis(partyBalances[msg.sender].totalExposureUSD);
        FHE.allow(partyBalances[msg.sender].totalExposureUSD, msg.sender);
        FHE.allowThis(partyBalances[msg.sender].dailyVolumeUSD);
        _systemDailyFXVolume = FHE.add(_systemDailyFXVolume, sellAmt);
        FHE.allowThis(_systemDailyFXVolume);
        emit TransactionBooked(txId, msg.sender, seller);
    }

    function confirmTransaction(uint256 txId) external {
        FXTransaction storage fxt = transactions[txId];
        require(msg.sender == fxt.buyer || msg.sender == fxt.seller, "Not party");
        require(!fxt.settled, "Already settled");
        if (msg.sender == fxt.buyer) fxt.buyerConfirmed = true;
        if (msg.sender == fxt.seller) fxt.sellerConfirmed = true;
        emit TransactionConfirmed(txId, msg.sender);
    }

    function settleTransaction(uint256 txId) external onlySettlementAgent nonReentrant {
        FXTransaction storage fxt = transactions[txId];
        require(fxt.buyerConfirmed && fxt.sellerConfirmed, "Not both confirmed");
        require(!fxt.settled, "Already settled");
        require(block.timestamp >= fxt.valueDate, "Value date not reached");
        // Execute currency exchange
        PartyBalance storage buyer = partyBalances[fxt.buyer];
        PartyBalance storage seller = partyBalances[fxt.seller];
        buyer.currencyBalances[uint8(fxt.buyCurrency)] = FHE.add(
            buyer.currencyBalances[uint8(fxt.buyCurrency)], fxt.buyAmountUnits);
        buyer.currencyBalances[uint8(fxt.sellCurrency)] = FHE.sub(
            buyer.currencyBalances[uint8(fxt.sellCurrency)], fxt.sellAmountUnits);
        seller.currencyBalances[uint8(fxt.sellCurrency)] = FHE.add(
            seller.currencyBalances[uint8(fxt.sellCurrency)], fxt.sellAmountUnits);
        seller.currencyBalances[uint8(fxt.buyCurrency)] = FHE.sub(
            seller.currencyBalances[uint8(fxt.buyCurrency)], fxt.buyAmountUnits);
        fxt.settled = true;
        // Reduce exposure
        ebool _safeSub192 = FHE.ge(buyer.totalExposureUSD, fxt.sellAmountUnits);
        buyer.totalExposureUSD = FHE.select(_safeSub192, FHE.sub(buyer.totalExposureUSD, fxt.sellAmountUnits), FHE.asEuint64(0));
        FHE.allowThis(buyer.currencyBalances[uint8(fxt.buyCurrency)]);
        FHE.allow(buyer.currencyBalances[uint8(fxt.buyCurrency)], fxt.buyer);
        FHE.allowThis(seller.currencyBalances[uint8(fxt.sellCurrency)]);
        FHE.allow(seller.currencyBalances[uint8(fxt.sellCurrency)], fxt.seller);
        FHE.allowThis(buyer.totalExposureUSD);
        emit TransactionSettled(txId);
    }

    function registerParty(
        address party,
        externalEuint64 encCreditLimit, bytes calldata clProof
    ) external onlyOwner {
        partyBalances[party].approved = true;
        partyBalances[party].creditLimitUSD = FHE.fromExternal(encCreditLimit, clProof);
        partyBalances[party].totalExposureUSD = FHE.asEuint64(0);
        partyBalances[party].dailyVolumeUSD = FHE.asEuint64(0);
        FHE.allowThis(partyBalances[party].creditLimitUSD);
        FHE.allow(partyBalances[party].creditLimitUSD, party);
        FHE.allowThis(partyBalances[party].totalExposureUSD);
        FHE.allow(partyBalances[party].totalExposureUSD, party);
    }

    function addFXDealer(address d) external onlyOwner { isFXDealer[d] = true; }
    function addSettlementAgent(address sa) external onlyOwner { isSettlementAgent[sa] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function allowSystemStats(address overseer) external onlyOwner {
        FHE.allow(_systemDailyFXVolume, overseer);
        FHE.allow(_systemNettingSavings, overseer);
    }
}
