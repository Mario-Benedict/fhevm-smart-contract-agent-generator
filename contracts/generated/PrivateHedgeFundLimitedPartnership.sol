// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHedgeFundLimitedPartnership
/// @notice Hedge fund LP structure with encrypted capital commitments, NAV,
///         performance fees (carried interest), and waterfall distributions.
contract PrivateHedgeFundLimitedPartnership is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FundStrategy { LONG_SHORT_EQUITY, GLOBAL_MACRO, QUANT_ARBITRAGE, CREDIT, DISTRESSED, MULTI_STRAT }
    enum LPStatus { COMMITTED, FUNDED, REDEEMED, DEFAULTED }

    struct LimitedPartner {
        string investorName;
        euint64 capitalCommitmentUSD;  // encrypted total commitment
        euint64 capitalCalledUSD;      // encrypted drawn down
        euint64 navUSD;                // encrypted current NAV
        euint64 unrealizedGainLoss;    // encrypted unrealized P&L
        euint64 distributionsReceived; // encrypted total distributions
        euint32 managementFeesBps;     // encrypted mgmt fee rate
        euint32 carriedInterestBps;    // encrypted carry rate
        uint256 subscriptionDate;
        LPStatus status;
        bool qualifiedPurchaser;
    }

    struct CapitalCall {
        uint256 callNumber;
        euint64 totalCallAmountUSD;    // encrypted total amount called
        euint64 callPerShareUSD;       // encrypted per unit call
        uint256 callDate;
        uint256 dueDate;
        bool settled;
    }

    struct Distribution {
        uint256 distNumber;
        euint64 totalDistributionUSD;  // encrypted total amount distributed
        euint64 perShareAmountUSD;     // encrypted per unit
        euint64 returnOfCapitalUSD;    // encrypted ROC portion
        euint64 gainPortionUSD;        // encrypted gain portion
        uint256 distributionDate;
        bool settled;
    }

    mapping(address => LimitedPartner) private lps;
    mapping(uint256 => CapitalCall) private capitalCalls;
    mapping(uint256 => Distribution) private distributions;
    mapping(address => bool) public isGP; // General Partner
    address[] private lpList;
    uint256 public capitalCallCount;
    uint256 public distributionCount;
    euint64 private _totalFundNAV;
    euint64 private _totalCapitalCalled;
    euint64 private _totalDistributed;
    euint64 private _managementFeesEarned;
    euint64 private _carriedInterestEarned;
    FundStrategy public fundStrategy;

    event LPOnboarded(address indexed lp, string name);
    event CapitalCallIssued(uint256 indexed callId);
    event CapitalCallSettled(address indexed lp, uint256 callId);
    event DistributionMade(uint256 indexed distId);

    constructor(FundStrategy strategy) Ownable(msg.sender) {
        fundStrategy = strategy;
        _totalFundNAV = FHE.asEuint64(0);
        _totalCapitalCalled = FHE.asEuint64(0);
        _totalDistributed = FHE.asEuint64(0);
        _managementFeesEarned = FHE.asEuint64(0);
        _carriedInterestEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalCapitalCalled);
        FHE.allowThis(_totalDistributed);
        FHE.allowThis(_managementFeesEarned);
        FHE.allowThis(_carriedInterestEarned);
        isGP[msg.sender] = true;
    }

    function addGP(address gp) external onlyOwner { isGP[gp] = true; }

    function onboardLP(
        address lpAddr,
        string calldata name,
        externalEuint64 encCommitment, bytes calldata commProof,
        externalEuint32 encMgmtFee,    bytes calldata mfProof,
        externalEuint32 encCarry,      bytes calldata carryProof,
        bool qualifiedPurchaser
    ) external {
        require(isGP[msg.sender], "Not GP");
        euint64 commitment = FHE.fromExternal(encCommitment, commProof);
        euint32 mgmtFee    = FHE.fromExternal(encMgmtFee, mfProof);
        euint32 carry      = FHE.fromExternal(encCarry, carryProof);
        lps[lpAddr] = LimitedPartner({
            investorName: name,
            capitalCommitmentUSD: commitment,
            capitalCalledUSD: FHE.asEuint64(0),
            navUSD: FHE.asEuint64(0),
            unrealizedGainLoss: FHE.asEuint64(0),
            distributionsReceived: FHE.asEuint64(0),
            managementFeesBps: mgmtFee,
            carriedInterestBps: carry,
            subscriptionDate: block.timestamp,
            status: LPStatus.COMMITTED,
            qualifiedPurchaser: qualifiedPurchaser
        });
        lpList.push(lpAddr);
        FHE.allowThis(lps[lpAddr].capitalCommitmentUSD);
        FHE.allow(lps[lpAddr].capitalCommitmentUSD, lpAddr);
        FHE.allowThis(lps[lpAddr].capitalCalledUSD);
        FHE.allow(lps[lpAddr].capitalCalledUSD, lpAddr);
        FHE.allowThis(lps[lpAddr].navUSD);
        FHE.allow(lps[lpAddr].navUSD, lpAddr);
        FHE.allowThis(lps[lpAddr].unrealizedGainLoss);
        FHE.allow(lps[lpAddr].unrealizedGainLoss, lpAddr);
        FHE.allowThis(lps[lpAddr].distributionsReceived);
        FHE.allow(lps[lpAddr].distributionsReceived, lpAddr);
        FHE.allowThis(lps[lpAddr].managementFeesBps);
        FHE.allowThis(lps[lpAddr].carriedInterestBps);
        emit LPOnboarded(lpAddr, name);
    }

    function issueCapitalCall(
        externalEuint64 encTotalCall, bytes calldata tcProof,
        externalEuint64 encPerShare,  bytes calldata psProof,
        uint256 dueDays
    ) external returns (uint256 callId) {
        require(isGP[msg.sender], "Not GP");
        euint64 totalCall = FHE.fromExternal(encTotalCall, tcProof);
        euint64 perShare  = FHE.fromExternal(encPerShare, psProof);
        callId = capitalCallCount++;
        capitalCalls[callId] = CapitalCall({
            callNumber: callId,
            totalCallAmountUSD: totalCall,
            callPerShareUSD: perShare,
            callDate: block.timestamp,
            dueDate: block.timestamp + dueDays * 1 days,
            settled: false
        });
        _totalCapitalCalled = FHE.add(_totalCapitalCalled, totalCall);
        FHE.allowThis(capitalCalls[callId].totalCallAmountUSD);
        FHE.allowThis(capitalCalls[callId].callPerShareUSD);
        FHE.allowThis(_totalCapitalCalled);
        emit CapitalCallIssued(callId);
    }

    function settleCapitalCall(address lpAddr, uint256 callId, externalEuint64 encAmount, bytes calldata proof) external {
        require(isGP[msg.sender], "Not GP");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        lps[lpAddr].capitalCalledUSD = FHE.add(lps[lpAddr].capitalCalledUSD, amount);
        lps[lpAddr].navUSD = FHE.add(lps[lpAddr].navUSD, amount);
        lps[lpAddr].status = LPStatus.FUNDED;
        _totalFundNAV = FHE.add(_totalFundNAV, amount);
        FHE.allowThis(lps[lpAddr].capitalCalledUSD);
        FHE.allowThis(lps[lpAddr].navUSD);
        FHE.allowThis(_totalFundNAV);
        emit CapitalCallSettled(lpAddr, callId);
    }

    function makeDistribution(
        externalEuint64 encTotalDist,  bytes calldata tdProof,
        externalEuint64 encPerShare,   bytes calldata psProof,
        externalEuint64 encROC,        bytes calldata rocProof,
        externalEuint64 encGain,       bytes calldata gainProof
    ) external returns (uint256 distId) {
        require(isGP[msg.sender], "Not GP");
        euint64 total  = FHE.fromExternal(encTotalDist, tdProof);
        euint64 perShr = FHE.fromExternal(encPerShare, psProof);
        euint64 roc    = FHE.fromExternal(encROC, rocProof);
        euint64 gain   = FHE.fromExternal(encGain, gainProof);
        distId = distributionCount++;
        distributions[distId] = Distribution({
            distNumber: distId,
            totalDistributionUSD: total,
            perShareAmountUSD: perShr,
            returnOfCapitalUSD: roc,
            gainPortionUSD: gain,
            distributionDate: block.timestamp,
            settled: true
        });
        _totalDistributed = FHE.add(_totalDistributed, total);
        _totalFundNAV = FHE.sub(_totalFundNAV, total);
        FHE.allowThis(distributions[distId].totalDistributionUSD);
        FHE.allowThis(distributions[distId].perShareAmountUSD);
        FHE.allowThis(distributions[distId].returnOfCapitalUSD);
        FHE.allowThis(distributions[distId].gainPortionUSD);
        FHE.allowThis(_totalDistributed);
        FHE.allowThis(_totalFundNAV);
        emit DistributionMade(distId);
    }

    function claimDistribution(uint256 distId) external nonReentrant {
        require(lps[msg.sender].status == LPStatus.FUNDED, "Not funded LP");
        euint64 perShare = distributions[distId].perShareAmountUSD;
        lps[msg.sender].distributionsReceived = FHE.add(lps[msg.sender].distributionsReceived, perShare);
        lps[msg.sender].navUSD = FHE.sub(lps[msg.sender].navUSD, perShare);
        FHE.allowThis(lps[msg.sender].distributionsReceived);
        FHE.allow(lps[msg.sender].distributionsReceived, msg.sender);
        FHE.allowThis(lps[msg.sender].navUSD);
    }

    function updateLPNAV(address lpAddr, externalEuint64 encNewNAV, bytes calldata proof) external {
        require(isGP[msg.sender], "Not GP");
        euint64 newNAV = FHE.fromExternal(encNewNAV, proof);
        lps[lpAddr].unrealizedGainLoss = FHE.sub(newNAV, lps[lpAddr].capitalCalledUSD);
        lps[lpAddr].navUSD = newNAV;
        FHE.allowThis(lps[lpAddr].navUSD);
        FHE.allow(lps[lpAddr].navUSD, lpAddr);
        FHE.allowThis(lps[lpAddr].unrealizedGainLoss);
        FHE.allow(lps[lpAddr].unrealizedGainLoss, lpAddr);
    }

    function allowFundView(address viewer) external onlyOwner {
        FHE.allow(_totalFundNAV, viewer);
        FHE.allow(_totalCapitalCalled, viewer);
        FHE.allow(_totalDistributed, viewer);
    }
}
