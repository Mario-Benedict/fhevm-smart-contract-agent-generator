// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHedgeFundStrategyVault
/// @notice Encrypted hedge fund strategy vault: hidden strategy performance,
///         private drawdown metrics, confidential allocation to sub-strategies,
///         and encrypted high-water mark fee calculations.
contract PrivateHedgeFundStrategyVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Hedge Fund Vault";
    string public constant symbol = "HFV";
    uint8  public constant decimals = 18;

    enum StrategyType { LongShort, GlobalMacro, EventDriven, Arbitrage, QuantHighFreq, CreditOpportunistic }

    struct SubStrategy {
        StrategyType strategyType;
        string strategyRef;
        euint64 allocatedCapitalUSD;   // encrypted allocation
        euint64 currentNAVUSD;         // encrypted NAV
        euint64 maxDrawdownBps;        // encrypted max drawdown
        euint64 sharpRatioX100;        // encrypted Sharpe * 100
        euint64 performanceFeeBps;     // encrypted perf fee rate
        euint64 highWaterMarkUSD;      // encrypted HWM
        euint64 performanceFeesAccruedUSD; // encrypted fees accrued
        bool active;
    }

    struct Investor {
        address wallet;
        euint64 sharesOwned;           // encrypted shares
        euint64 investedCapitalUSD;    // encrypted invested
        euint64 unrealizedPnLUSD;      // encrypted P&L
        uint256 investedAt;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => SubStrategy) private strategies;
    mapping(uint256 => Investor) private investors;
    mapping(address => uint256) private investorIdByWallet;

    euint64 private _totalSupply;
    euint64 private _totalFundNAVUSD;
    euint64 private _totalMgmtFeesUSD;
    euint64 private _totalPerfFeesUSD;

    uint256 public strategyCount;
    uint256 public investorCount;

    event Transfer(address indexed from, address indexed to);
    event StrategyAdded(uint256 indexed id, StrategyType strategyType);
    event NAVUpdated(uint256 indexed strategyId, uint256 updatedAt);
    event InvestorOnboarded(uint256 indexed id, address investor);

    modifier onlyFundManager() {
        require(msg.sender == owner(), "Not fund manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0); _totalFundNAVUSD = FHE.asEuint64(0);
        _totalMgmtFeesUSD = FHE.asEuint64(0); _totalPerfFeesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalFundNAVUSD);
        FHE.allowThis(_totalMgmtFeesUSD); FHE.allowThis(_totalPerfFeesUSD);
    }

    function addStrategy(
        StrategyType strategyType, string calldata strategyRef,
        externalEuint64 encAllocation, bytes calldata alProof,
        externalEuint64 encPerfFee, bytes calldata pfProof,
        externalEuint64 encSharpRatio, bytes calldata srProof
    ) external onlyFundManager returns (uint256 id) {
        euint64 allocation = FHE.fromExternal(encAllocation, alProof);
        euint64 perfFee    = FHE.fromExternal(encPerfFee, pfProof);
        euint64 sharpRatio = FHE.fromExternal(encSharpRatio, srProof);
        id = strategyCount++;
        strategies[id].strategyType = strategyType;
        strategies[id].strategyRef = strategyRef;
        strategies[id].allocatedCapitalUSD = allocation;
        strategies[id].currentNAVUSD = allocation;
        strategies[id].maxDrawdownBps = FHE.asEuint64(0);
        strategies[id].sharpRatioX100 = sharpRatio;
        strategies[id].performanceFeeBps = perfFee;
        strategies[id].highWaterMarkUSD = allocation;
        strategies[id].performanceFeesAccruedUSD = FHE.asEuint64(0);
        strategies[id].active = true;
        _totalFundNAVUSD = FHE.add(_totalFundNAVUSD, allocation);
        FHE.allowThis(strategies[id].allocatedCapitalUSD); FHE.allow(strategies[id].allocatedCapitalUSD, msg.sender);
        FHE.allowThis(strategies[id].currentNAVUSD); FHE.allow(strategies[id].currentNAVUSD, msg.sender);
        FHE.allowThis(strategies[id].maxDrawdownBps); FHE.allowThis(strategies[id].sharpRatioX100);
        FHE.allowThis(strategies[id].performanceFeeBps); FHE.allow(strategies[id].performanceFeeBps, msg.sender);
        FHE.allowThis(strategies[id].highWaterMarkUSD); FHE.allow(strategies[id].highWaterMarkUSD, msg.sender);
        FHE.allowThis(strategies[id].performanceFeesAccruedUSD); FHE.allow(strategies[id].performanceFeesAccruedUSD, msg.sender);
        FHE.allowThis(_totalFundNAVUSD);
        emit StrategyAdded(id, strategyType);
    }

    function updateStrategyNAV(uint256 strategyId, externalEuint64 encNewNAV, bytes calldata proof) external onlyFundManager {
        SubStrategy storage s = strategies[strategyId];
        euint64 newNAV = FHE.fromExternal(encNewNAV, proof);
        _totalFundNAVUSD = FHE.sub(_totalFundNAVUSD, s.currentNAVUSD);
        _totalFundNAVUSD = FHE.add(_totalFundNAVUSD, newNAV);
        // Performance fee above HWM
        ebool aboveHWM = FHE.gt(newNAV, s.highWaterMarkUSD);
        euint64 gain = FHE.select(aboveHWM, FHE.sub(newNAV, s.highWaterMarkUSD), FHE.asEuint64(0));
        euint64 perfFee = FHE.div(FHE.mul(gain, s.performanceFeeBps), 10000);
        s.performanceFeesAccruedUSD = FHE.add(s.performanceFeesAccruedUSD, perfFee);
        _totalPerfFeesUSD = FHE.add(_totalPerfFeesUSD, perfFee);
        s.highWaterMarkUSD = FHE.select(aboveHWM, newNAV, s.highWaterMarkUSD);
        s.currentNAVUSD = newNAV;
        FHE.allowThis(s.currentNAVUSD); FHE.allow(s.currentNAVUSD, msg.sender);
        FHE.allowThis(s.performanceFeesAccruedUSD); FHE.allow(s.performanceFeesAccruedUSD, msg.sender);
        FHE.allowThis(s.highWaterMarkUSD); FHE.allow(s.highWaterMarkUSD, msg.sender);
        FHE.allowThis(_totalFundNAVUSD); FHE.allowThis(_totalPerfFeesUSD);
        emit NAVUpdated(strategyId, block.timestamp);
    }

    function onboardInvestor(address wallet, externalEuint64 encShares, bytes calldata sProof, externalEuint64 encCapital, bytes calldata cProof) external onlyFundManager returns (uint256 id) {
        euint64 shares  = FHE.fromExternal(encShares, sProof);
        euint64 capital = FHE.fromExternal(encCapital, cProof);
        id = investorCount++;
        investorIdByWallet[wallet] = id;
        investors[id] = Investor({ wallet: wallet, sharesOwned: shares, investedCapitalUSD: capital, unrealizedPnLUSD: FHE.asEuint64(0), investedAt: block.timestamp });
        if (!FHE.isInitialized(_balances[wallet])) { _balances[wallet] = FHE.asEuint64(0); FHE.allowThis(_balances[wallet]); }
        _balances[wallet] = FHE.add(_balances[wallet], shares);
        _totalSupply = FHE.add(_totalSupply, shares);
        FHE.allowThis(investors[id].sharesOwned); FHE.allow(investors[id].sharesOwned, wallet);
        FHE.allowThis(investors[id].investedCapitalUSD); FHE.allow(investors[id].investedCapitalUSD, wallet);
        FHE.allowThis(investors[id].unrealizedPnLUSD); FHE.allow(investors[id].unrealizedPnLUSD, wallet);
        FHE.allowThis(_balances[wallet]); FHE.allow(_balances[wallet], wallet);
        FHE.allowThis(_totalSupply);
        emit InvestorOnboarded(id, wallet);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalFundNAVUSD, viewer); FHE.allow(_totalMgmtFeesUSD, viewer); FHE.allow(_totalPerfFeesUSD, viewer);
    }
}
