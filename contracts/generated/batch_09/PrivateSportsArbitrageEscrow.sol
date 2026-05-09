// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSportsArbitrageEscrow
/// @notice Multi-platform sports arbitrage escrow: encrypted bet positions across bookmakers,
///         confidential hedge ratios, private profit locks, and encrypted payout calculations
///         for multi-leg arb opportunities.
contract PrivateSportsArbitrageEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum SportType { Football, Basketball, Tennis, Cricket, Baseball, MMA }
    enum ArbStatus { Open, Hedged, Settling, Settled, Voided }

    struct ArbitrageOpportunity {
        address arbTrader;
        SportType sportType;
        string eventRef;
        euint64 leg1StakeUSD;          // encrypted stake on outcome A
        euint64 leg2StakeUSD;          // encrypted stake on outcome B
        euint64 leg1OddsBps;           // encrypted decimal odds bps (e.g. 20000 = 2.0x)
        euint64 leg2OddsBps;           // encrypted decimal odds bps
        euint64 guaranteedProfitUSD;   // encrypted locked-in profit
        euint64 totalExposureUSD;      // encrypted total capital deployed
        ArbStatus status;
        uint256 eventDate;
    }

    struct ArbSettlement {
        uint256 arbId;
        uint8 winningLeg;              // 1 or 2 (plaintext after event resolution)
        euint64 payoutReceivedUSD;     // encrypted payout from winning side
        euint64 netProfitUSD;          // encrypted net profit after both legs
        uint256 settledAt;
    }

    mapping(uint256 => ArbitrageOpportunity) private arbs;
    mapping(uint256 => ArbSettlement) private settlements;
    mapping(address => bool) public isOddsOracle;

    uint256 public arbCount;
    uint256 public settlementCount;
    euint64 private _totalCapitalDeployedUSD;
    euint64 private _totalProfitLockedUSD;

    event ArbOpened(uint256 indexed arbId, SportType sportType, string eventRef);
    event ArbSettled(uint256 indexed settlementId, uint256 arbId, uint8 winningLeg);

    modifier onlyOddsOracle() {
        require(isOddsOracle[msg.sender] || msg.sender == owner(), "Not odds oracle");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCapitalDeployedUSD = FHE.asEuint64(0);
        _totalProfitLockedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCapitalDeployedUSD);
        FHE.allowThis(_totalProfitLockedUSD);
        isOddsOracle[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addOddsOracle(address o) external onlyOwner { isOddsOracle[o] = true; }

    function openArb(
        SportType sportType,
        string calldata eventRef,
        externalEuint64 encStake1, bytes calldata s1Proof,
        externalEuint64 encStake2, bytes calldata s2Proof,
        externalEuint64 encOdds1, bytes calldata o1Proof,
        externalEuint64 encOdds2, bytes calldata o2Proof,
        externalEuint64 encProfit, bytes calldata profProof,
        uint256 eventDate
    ) external whenNotPaused returns (uint256 arbId) {
        euint64 stake1 = FHE.fromExternal(encStake1, s1Proof);
        euint64 stake2 = FHE.fromExternal(encStake2, s2Proof);
        euint64 odds1 = FHE.fromExternal(encOdds1, o1Proof);
        euint64 odds2 = FHE.fromExternal(encOdds2, o2Proof);
        euint64 profit = FHE.fromExternal(encProfit, profProof);
        euint64 totalExposure = FHE.add(stake1, stake2);
        arbId = arbCount++;
        arbs[arbId].arbTrader = msg.sender;
        arbs[arbId].sportType = sportType;
        arbs[arbId].eventRef = eventRef;
        arbs[arbId].leg1StakeUSD = stake1;
        arbs[arbId].leg2StakeUSD = stake2;
        arbs[arbId].leg1OddsBps = odds1;
        arbs[arbId].leg2OddsBps = odds2;
        arbs[arbId].guaranteedProfitUSD = profit;
        arbs[arbId].totalExposureUSD = totalExposure;
        arbs[arbId].status = ArbStatus.Open;
        arbs[arbId].eventDate = eventDate;
        _totalCapitalDeployedUSD = FHE.add(_totalCapitalDeployedUSD, totalExposure);
        _totalProfitLockedUSD = FHE.add(_totalProfitLockedUSD, profit);
        FHE.allowThis(arbs[arbId].leg1StakeUSD); FHE.allow(arbs[arbId].leg1StakeUSD, msg.sender);
        FHE.allowThis(arbs[arbId].leg2StakeUSD); FHE.allow(arbs[arbId].leg2StakeUSD, msg.sender);
        FHE.allowThis(arbs[arbId].leg1OddsBps); FHE.allow(arbs[arbId].leg1OddsBps, msg.sender);
        FHE.allowThis(arbs[arbId].leg2OddsBps); FHE.allow(arbs[arbId].leg2OddsBps, msg.sender);
        FHE.allowThis(arbs[arbId].guaranteedProfitUSD); FHE.allow(arbs[arbId].guaranteedProfitUSD, msg.sender);
        FHE.allowThis(arbs[arbId].totalExposureUSD); FHE.allow(arbs[arbId].totalExposureUSD, msg.sender);
        FHE.allowThis(_totalCapitalDeployedUSD);
        FHE.allowThis(_totalProfitLockedUSD);
        emit ArbOpened(arbId, sportType, eventRef);
    }

    function settleArb(
        uint256 arbId,
        uint8 winningLeg,
        externalEuint64 encPayout, bytes calldata payProof
    ) external onlyOddsOracle nonReentrant {
        ArbitrageOpportunity storage arb = arbs[arbId];
        require(arb.status == ArbStatus.Open && block.timestamp >= arb.eventDate, "Not settleable");
        require(winningLeg == 1 || winningLeg == 2, "Invalid leg");
        euint64 payout = FHE.fromExternal(encPayout, payProof);
        euint64 totalStakes = FHE.add(arb.leg1StakeUSD, arb.leg2StakeUSD);
        euint64 netProfit = FHE.sub(payout, totalStakes);
        arb.status = ArbStatus.Settled;
        uint256 sId = settlementCount++;
        settlements[sId] = ArbSettlement({
            arbId: arbId, winningLeg: winningLeg, payoutReceivedUSD: payout,
            netProfitUSD: netProfit, settledAt: block.timestamp
        });
        _totalCapitalDeployedUSD = FHE.sub(_totalCapitalDeployedUSD, arb.totalExposureUSD);
        FHE.allowThis(settlements[sId].payoutReceivedUSD); FHE.allow(settlements[sId].payoutReceivedUSD, arb.arbTrader);
        FHE.allowThis(settlements[sId].netProfitUSD); FHE.allow(settlements[sId].netProfitUSD, arb.arbTrader);
        FHE.allowThis(_totalCapitalDeployedUSD);
        emit ArbSettled(sId, arbId, winningLeg);
    }

    function allowPlatformStats(address viewer) external onlyOwner {
        FHE.allow(_totalCapitalDeployedUSD, viewer);
        FHE.allow(_totalProfitLockedUSD, viewer);
    }
}
