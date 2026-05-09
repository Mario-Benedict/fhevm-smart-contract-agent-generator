// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCryptocurrencyOTCDealerBook
/// @notice Institutional OTC cryptocurrency dealer with encrypted quote spreads,
///         client credit limits, position limits, P&L attribution, and
///         confidential markup/markdown over exchange mid-market rates.
contract EncryptedCryptocurrencyOTCDealerBook is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AssetType { BTC, ETH, USDC, USDT, SOL, MATIC, AVAX, ARB, OP, OTHER }
    enum TradeDirection { BUY, SELL }
    enum ClientTier { RETAIL, PROFESSIONAL, INSTITUTIONAL, PRIME }

    struct DealerPosition {
        AssetType asset;
        euint64 longInventory;           // encrypted long book position
        euint64 shortInventory;          // encrypted short book position
        euint64 netPosition;             // encrypted net exposure
        euint64 averageBuyPrice;         // encrypted average buy price
        euint64 averageSellPrice;        // encrypted average sell price
        euint64 unrealizedPnL;           // encrypted unrealized P&L
        euint64 realizedPnL;             // encrypted realized P&L
        euint64 dailyVaR;                // encrypted daily Value-at-Risk
        euint64 positionLimit;           // encrypted max position limit
        euint64 markToMarketValue;       // encrypted MTM value
    }

    struct ClientQuote {
        address client;
        TradeDirection direction;
        AssetType asset;
        euint64 notionalAmount;          // encrypted trade notional USD
        euint64 dealerMidPrice;          // encrypted dealer's mid price
        euint64 spread;                  // encrypted bid-offer spread
        euint64 clientRate;              // encrypted rate shown to client
        euint64 dealerMarkup;            // encrypted dealer markup/markdown
        euint64 clientCreditUsed;        // encrypted credit consumed
        bool filled;
        uint256 quoteTime;
        uint256 expiryTime;
    }

    struct ClientProfile {
        ClientTier tier;
        euint64 creditLimit;             // encrypted credit limit
        euint64 creditUtilized;          // encrypted used credit
        euint64 totalVolumeTraded;       // encrypted total volume
        euint64 totalFeePaid;            // encrypted total fee/markup paid
        euint64 pnlFromDealer;           // encrypted client P&L vs dealer
        bool active;
        bool kycVerified;
    }

    mapping(AssetType => DealerPosition) private book;
    mapping(bytes32 => ClientQuote) private quotes;
    mapping(address => ClientProfile) private clients;
    mapping(address => bool) public authorizedClient;

    euint64 private _totalDealerPnL;       // encrypted total dealer P&L
    euint64 private _totalVolumeAllAssets; // encrypted total volume all assets
    euint64 private _totalMarkupEarned;    // encrypted total markup collected

    event ClientOnboarded(address indexed client, ClientTier tier);
    event QuoteIssued(bytes32 indexed quoteId, address indexed client, AssetType asset);
    event TradeFilled(bytes32 indexed quoteId);
    event PositionUpdated(AssetType indexed asset);
    event CreditLimitBreached(address indexed client);

    constructor() Ownable(msg.sender) {
        _totalDealerPnL = FHE.asEuint64(0);
        _totalVolumeAllAssets = FHE.asEuint64(0);
        _totalMarkupEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalDealerPnL);
        FHE.allowThis(_totalVolumeAllAssets);
        FHE.allowThis(_totalMarkupEarned);
    }

    function onboardClient(
        address client,
        ClientTier tier,
        externalEuint64 encCreditLimit, bytes calldata clProof
    ) external onlyOwner {
        euint64 creditLimit = FHE.fromExternal(encCreditLimit, clProof);
        clients[client] = ClientProfile({
            tier: tier, creditLimit: creditLimit,
            creditUtilized: FHE.asEuint64(0), totalVolumeTraded: FHE.asEuint64(0),
            totalFeePaid: FHE.asEuint64(0), pnlFromDealer: FHE.asEuint64(0),
            active: true, kycVerified: true
        });
        authorizedClient[client] = true;
        FHE.allowThis(creditLimit); FHE.allow(creditLimit, client);
        FHE.allowThis(clients[client].creditUtilized);
        FHE.allow(clients[client].creditUtilized, client);
        FHE.allowThis(clients[client].totalVolumeTraded);
        FHE.allow(clients[client].totalVolumeTraded, client);
        FHE.allowThis(clients[client].totalFeePaid);
        FHE.allow(clients[client].totalFeePaid, client);
        FHE.allowThis(clients[client].pnlFromDealer);
        FHE.allow(clients[client].pnlFromDealer, client);
        emit ClientOnboarded(client, tier);
    }

    function issueQuote(
        address client,
        TradeDirection direction,
        AssetType asset,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encMidPrice, bytes calldata mpProof,
        externalEuint64 encSpread, bytes calldata spProof,
        externalEuint64 encMarkup, bytes calldata mkProof,
        uint256 validForSeconds
    ) external onlyOwner returns (bytes32 quoteId) {
        require(authorizedClient[client], "Not authorized client");
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 midPrice = FHE.fromExternal(encMidPrice, mpProof);
        euint64 spread = FHE.fromExternal(encSpread, spProof);
        euint64 markup = FHE.fromExternal(encMarkup, mkProof);

        // Client rate = mid +/- spread/2 +/- markup
        euint64 halfSpread = FHE.div(spread, 2);
        euint64 clientRate = direction == TradeDirection.BUY
            ? FHE.add(FHE.add(midPrice, halfSpread), markup)
            : FHE.sub(FHE.sub(midPrice, halfSpread), markup);

        quoteId = keccak256(abi.encodePacked(client, asset, block.timestamp));
        quotes[quoteId] = ClientQuote({
            client: client, direction: direction, asset: asset,
            notionalAmount: notional, dealerMidPrice: midPrice,
            spread: spread, clientRate: clientRate,
            dealerMarkup: markup, clientCreditUsed: notional,
            filled: false, quoteTime: block.timestamp,
            expiryTime: block.timestamp + validForSeconds
        });

        FHE.allowThis(notional); FHE.allow(notional, client);
        FHE.allowThis(midPrice); FHE.allow(midPrice, client);
        FHE.allowThis(clientRate); FHE.allow(clientRate, client);
        FHE.allowThis(spread); FHE.allowThis(markup);
        FHE.allowThis(quotes[quoteId].clientCreditUsed);
        emit QuoteIssued(quoteId, client, asset);
    }

    function fillQuote(bytes32 quoteId) external nonReentrant {
        ClientQuote storage q = quotes[quoteId];
        require(q.client == msg.sender, "Not client");
        require(!q.filled, "Already filled");
        require(block.timestamp <= q.expiryTime, "Quote expired");

        ClientProfile storage client = clients[msg.sender];
        ebool creditOk = FHE.le(FHE.add(client.creditUtilized, q.notionalAmount), client.creditLimit);

        client.creditUtilized = FHE.select(creditOk,
            FHE.add(client.creditUtilized, q.notionalAmount),
            client.creditLimit);
        client.totalVolumeTraded = FHE.add(client.totalVolumeTraded, q.notionalAmount);
        client.totalFeePaid = FHE.add(client.totalFeePaid, q.dealerMarkup);

        _totalVolumeAllAssets = FHE.add(_totalVolumeAllAssets, q.notionalAmount);
        _totalMarkupEarned = FHE.add(_totalMarkupEarned, q.dealerMarkup);
        _totalDealerPnL = FHE.add(_totalDealerPnL, q.dealerMarkup);

        q.filled = true;
        DealerPosition storage pos = book[q.asset];
        if (q.direction == TradeDirection.BUY) {
            pos.longInventory = FHE.add(pos.longInventory, q.notionalAmount);
        } else {
            pos.shortInventory = FHE.add(pos.shortInventory, q.notionalAmount);
        }

        FHE.allowThis(client.creditUtilized); FHE.allow(client.creditUtilized, msg.sender);
        FHE.allowThis(client.totalVolumeTraded); FHE.allow(client.totalVolumeTraded, msg.sender);
        FHE.allowThis(client.totalFeePaid); FHE.allow(client.totalFeePaid, msg.sender);
        FHE.allowThis(_totalVolumeAllAssets);
        FHE.allowThis(_totalMarkupEarned);
        FHE.allowThis(_totalDealerPnL);
        FHE.allowThis(pos.longInventory);
        FHE.allowThis(pos.shortInventory);

        emit TradeFilled(quoteId);
        emit PositionUpdated(q.asset);
    }

    function initializeBookPosition(
        AssetType asset,
        externalEuint64 encPositionLimit, bytes calldata plProof
    ) external onlyOwner {
        euint64 posLimit = FHE.fromExternal(encPositionLimit, plProof);
        book[asset].asset = asset;
        book[asset].positionLimit = posLimit;
        book[asset].longInventory = FHE.asEuint64(0);
        book[asset].shortInventory = FHE.asEuint64(0);
        book[asset].netPosition = FHE.asEuint64(0);
        book[asset].averageBuyPrice = FHE.asEuint64(0);
        book[asset].averageSellPrice = FHE.asEuint64(0);
        book[asset].unrealizedPnL = FHE.asEuint64(0);
        book[asset].realizedPnL = FHE.asEuint64(0);
        book[asset].dailyVaR = FHE.asEuint64(0);
        book[asset].markToMarketValue = FHE.asEuint64(0);
        FHE.allowThis(posLimit);
        FHE.allowThis(book[asset].longInventory);
        FHE.allowThis(book[asset].shortInventory);
        FHE.allowThis(book[asset].netPosition);
        FHE.allowThis(book[asset].averageBuyPrice);
        FHE.allowThis(book[asset].averageSellPrice);
        FHE.allowThis(book[asset].unrealizedPnL);
        FHE.allowThis(book[asset].realizedPnL);
        FHE.allowThis(book[asset].dailyVaR);
        FHE.allowThis(book[asset].markToMarketValue);
    }

    function allowDealerStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalDealerPnL, viewer);
        FHE.allow(_totalVolumeAllAssets, viewer);
        FHE.allow(_totalMarkupEarned, viewer);
    }
}
