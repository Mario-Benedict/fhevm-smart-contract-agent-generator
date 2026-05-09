// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMergerArbitrageVault - Encrypted M&A arb positions with confidential spread and sizing
contract PrivateMergerArbitrageVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DealPosition {
        string  targetCompany;
        string  acquirerCompany;
        euint64 offerPrice;         // encrypted deal price per share
        euint64 currentMarketPrice; // encrypted current trading price
        euint64 positionSize;       // encrypted number of shares held
        euint64 impliedSpread;      // offerPrice - currentMarketPrice
        uint256 expectedClose;
        bool    completed;
        bool    broken;
    }

    mapping(uint256 => DealPosition) public deals;
    mapping(address => mapping(uint256 => euint64)) private investorExposure;
    mapping(address => euint64) public investorPnL;
    mapping(address => bool) private _pnlInitialized;
    mapping(address => bool) public qualifiedInvestors;
    uint256 public dealCount;
    euint64 private vaultTotalExposure;

    event DealOpened(uint256 indexed dealId, string target);
    event ExposureTaken(uint256 indexed dealId, address indexed investor);
    event DealCompleted(uint256 indexed dealId);
    event DealBroken(uint256 indexed dealId);
    event PnLBooked(uint256 indexed dealId, address indexed investor);

    constructor() Ownable(msg.sender) {
        vaultTotalExposure = FHE.asEuint64(0);
        FHE.allowThis(vaultTotalExposure);
    }

    function qualifyInvestor(address investor) external onlyOwner {
        qualifiedInvestors[investor] = true;
    }

    function openDeal(
        string calldata target, string calldata acquirer,
        externalEuint64 encOffer,   bytes calldata offerProof,
        externalEuint64 encMarket,  bytes calldata marketProof,
        uint256 expectedCloseDays
    ) external onlyOwner returns (uint256 dealId) {
        dealId = dealCount++;
        DealPosition storage d = deals[dealId];
        d.targetCompany   = target;
        d.acquirerCompany = acquirer;
        d.offerPrice         = FHE.fromExternal(encOffer,  offerProof);
        d.currentMarketPrice = FHE.fromExternal(encMarket, marketProof);
        d.positionSize       = FHE.asEuint64(0);
        d.impliedSpread      = FHE.sub(d.offerPrice, d.currentMarketPrice);
        d.expectedClose      = block.timestamp + expectedCloseDays * 1 days;
        FHE.allowThis(d.offerPrice); FHE.allowThis(d.currentMarketPrice);
        FHE.allowThis(d.positionSize); FHE.allowThis(d.impliedSpread);
        FHE.allow(d.impliedSpread, owner());
        emit DealOpened(dealId, target);
    }

    function takeExposure(
        uint256 dealId,
        externalEuint64 encShares, bytes calldata inputProof
    ) external nonReentrant {
        require(qualifiedInvestors[msg.sender], "Not qualified");
        DealPosition storage d = deals[dealId];
        require(!d.completed && !d.broken, "Deal closed");
        euint64 shares = FHE.fromExternal(encShares, inputProof);
        investorExposure[msg.sender][dealId] = FHE.add(investorExposure[msg.sender][dealId], shares);
        d.positionSize = FHE.add(d.positionSize, shares);
        vaultTotalExposure = FHE.add(vaultTotalExposure, shares);
        FHE.allowThis(investorExposure[msg.sender][dealId]);
        FHE.allowThis(d.positionSize); FHE.allowThis(vaultTotalExposure);
        FHE.allow(investorExposure[msg.sender][dealId], msg.sender);
        if (!_pnlInitialized[msg.sender]) {
            investorPnL[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(investorPnL[msg.sender]);
            _pnlInitialized[msg.sender] = true;
        }
        emit ExposureTaken(dealId, msg.sender);
    }

    function completeDeal(uint256 dealId) external onlyOwner {
        deals[dealId].completed = true;
        emit DealCompleted(dealId);
    }

    function breakDeal(uint256 dealId) external onlyOwner {
        deals[dealId].broken = true;
        emit DealBroken(dealId);
    }

    function bookPnL(uint256 dealId, address investor) external onlyOwner nonReentrant {
        DealPosition storage d = deals[dealId];
        require(d.completed || d.broken, "Still open");
        euint64 exposure = investorExposure[investor][dealId];
        euint64 pnl;
        if (d.completed) {
            pnl = FHE.mul(exposure, d.impliedSpread);
        } else {
            pnl = FHE.asEuint64(0); // deal broken, no profit
        }
        investorPnL[investor] = FHE.add(investorPnL[investor], pnl);
        investorExposure[investor][dealId] = FHE.asEuint64(0);
        FHE.allowThis(investorPnL[investor]); FHE.allowThis(investorExposure[investor][dealId]);
        FHE.allow(investorPnL[investor], investor);
        emit PnLBooked(dealId, investor);
    }
}
