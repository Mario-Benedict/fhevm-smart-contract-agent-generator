// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedInsiderTradingMonitor
/// @notice On-chain compliance tool: executives submit encrypted trades, 
///         compliance verifies blackout periods and encrypted position thresholds.
contract EncryptedInsiderTradingMonitor is ZamaEthereumConfig, Ownable {
    enum TradeDirection { Buy, Sell }

    struct Insider {
        string title;
        euint64 maxPositionSizeUSD;   // encrypted max allowed position
        euint64 currentHoldingsUSD;   // encrypted current holdings
        bool registered;
        bool blackoutActive;
    }

    struct TradeReport {
        address insider;
        TradeDirection direction;
        euint64 tradeValueUSD;        // encrypted trade size
        euint64 positionAfterUSD;     // encrypted position post-trade
        euint8 complianceScore;       // encrypted 0-100 compliance rating
        string securityTicker;
        uint256 reportedAt;
        bool reviewed;
        bool flagged;
    }

    mapping(address => Insider) private insiders;
    mapping(uint256 => TradeReport) private tradeReports;
    mapping(address => bool) public isComplianceOfficer;
    uint256 public reportCount;
    euint64 private _totalSuspiciousValue;
    uint256 public blackoutStart;
    uint256 public blackoutEnd;

    event InsiderRegistered(address indexed insider, string title);
    event TradeReported(uint256 indexed reportId, address insider);
    event TradeFlagged(uint256 indexed reportId, string reason);
    event BlackoutPeriodSet(uint256 start, uint256 end);

    modifier onlyComplianceOfficer() {
        require(isComplianceOfficer[msg.sender] || msg.sender == owner(), "Not compliance officer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSuspiciousValue = FHE.asEuint64(0);
        FHE.allowThis(_totalSuspiciousValue);
        isComplianceOfficer[msg.sender] = true;
    }

    function addComplianceOfficer(address co) external onlyOwner { isComplianceOfficer[co] = true; }

    function registerInsider(
        address insider, string calldata title,
        externalEuint64 encMaxPosition, bytes calldata proof
    ) external onlyComplianceOfficer {
        euint64 maxPos = FHE.fromExternal(encMaxPosition, proof);
        insiders[insider] = Insider({
            title: title, maxPositionSizeUSD: maxPos,
            currentHoldingsUSD: FHE.asEuint64(0), registered: true, blackoutActive: false
        });
        FHE.allowThis(insiders[insider].maxPositionSizeUSD);
        FHE.allow(insiders[insider].maxPositionSizeUSD, insider);
        FHE.allowThis(insiders[insider].currentHoldingsUSD);
        FHE.allow(insiders[insider].currentHoldingsUSD, insider);
        emit InsiderRegistered(insider, title);
    }

    function setBlackoutPeriod(uint256 start, uint256 end_) external onlyComplianceOfficer {
        require(end_ > start, "Invalid period");
        blackoutStart = start;
        blackoutEnd = end_;
        emit BlackoutPeriodSet(start, end_);
    }

    function activateInsiderBlackout(address insider) external onlyComplianceOfficer {
        insiders[insider].blackoutActive = true;
    }

    function liftInsiderBlackout(address insider) external onlyComplianceOfficer {
        insiders[insider].blackoutActive = false;
    }

    function reportTrade(
        string calldata ticker, TradeDirection direction,
        externalEuint64 encTradeValue, bytes calldata tvProof,
        externalEuint64 encPositionAfter, bytes calldata paProof,
        externalEuint8 encComplianceScore, bytes calldata csProof
    ) external returns (uint256 reportId) {
        Insider storage ins = insiders[msg.sender];
        require(ins.registered, "Not insider");
        euint64 tradeValue = FHE.fromExternal(encTradeValue, tvProof);
        euint64 posAfter = FHE.fromExternal(encPositionAfter, paProof);
        euint8 compScore = FHE.fromExternal(encComplianceScore, csProof);
        reportId = reportCount++;
        tradeReports[reportId] = TradeReport({
            insider: msg.sender, direction: direction, tradeValueUSD: tradeValue,
            positionAfterUSD: posAfter, complianceScore: compScore, securityTicker: ticker,
            reportedAt: block.timestamp, reviewed: false, flagged: false
        });
        // Update insider holdings
        if (direction == TradeDirection.Buy) {
            ins.currentHoldingsUSD = FHE.add(ins.currentHoldingsUSD, tradeValue);
        } else {
            ins.currentHoldingsUSD = FHE.sub(ins.currentHoldingsUSD, tradeValue);
        }
        FHE.allowThis(tradeReports[reportId].tradeValueUSD);
        FHE.allow(tradeReports[reportId].tradeValueUSD, msg.sender);
        FHE.allowThis(tradeReports[reportId].positionAfterUSD);
        FHE.allow(tradeReports[reportId].positionAfterUSD, msg.sender);
        FHE.allowThis(tradeReports[reportId].complianceScore);
        FHE.allowThis(ins.currentHoldingsUSD);
        FHE.allow(ins.currentHoldingsUSD, msg.sender);
        emit TradeReported(reportId, msg.sender);
    }

    function reviewTrade(uint256 reportId) external onlyComplianceOfficer {
        TradeReport storage tr = tradeReports[reportId];
        require(!tr.reviewed, "Already reviewed");
        tr.reviewed = true;
        // Check blackout period
        bool inBlackout = block.timestamp >= blackoutStart && block.timestamp <= blackoutEnd;
        if (inBlackout || insiders[tr.insider].blackoutActive) {
            tr.flagged = true;
            _totalSuspiciousValue = FHE.add(_totalSuspiciousValue, tr.tradeValueUSD);
            FHE.allowThis(_totalSuspiciousValue);
            emit TradeFlagged(reportId, "Blackout violation");
            return;
        }
        // Check position limit
        ebool exceedsLimit = FHE.gt(tr.positionAfterUSD, insiders[tr.insider].maxPositionSizeUSD);
        if (FHE.isInitialized(exceedsLimit)) {
            tr.flagged = true;
            _totalSuspiciousValue = FHE.add(_totalSuspiciousValue, tr.tradeValueUSD);
            FHE.allowThis(_totalSuspiciousValue);
            emit TradeFlagged(reportId, "Position limit exceeded");
        }
    }

    function allowTradeReport(uint256 reportId, address viewer) external onlyComplianceOfficer {
        FHE.allow(tradeReports[reportId].tradeValueUSD, viewer);
        FHE.allow(tradeReports[reportId].positionAfterUSD, viewer);
        FHE.allow(tradeReports[reportId].complianceScore, viewer);
    }

    function allowComplianceStats(address viewer) external onlyOwner {
        FHE.allow(_totalSuspiciousValue, viewer);
    }
}
