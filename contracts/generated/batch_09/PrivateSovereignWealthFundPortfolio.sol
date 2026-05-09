// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSovereignWealthFundPortfolio
/// @notice Encrypted sovereign wealth fund portfolio: hidden asset class allocations,
///         confidential co-investment deal terms, private benchmark outperformance data,
///         and encrypted strategic reserve thresholds.
contract PrivateSovereignWealthFundPortfolio is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetClass { PublicEquity, FixedIncome, Alternatives, Infrastructure, RealEstate, CashEquiv }
    enum GovernanceType { Authoritarian, GovernmentBoard, IndependentCIO, SovereignMandated }

    struct PortfolioAllocation {
        string fundName;
        string sovereignEntity;
        GovernanceType govType;
        euint64 totalAUMUSD;           // encrypted AUM
        euint64 publicEquityUSD;       // encrypted public equity allocation
        euint64 fixedIncomeUSD;        // encrypted bonds allocation
        euint64 alternativesUSD;       // encrypted alternative assets
        euint64 infrastructureUSD;     // encrypted infrastructure
        euint64 realEstateUSD;         // encrypted real estate
        euint64 cashReserveUSD;        // encrypted strategic reserve
        euint16 annualReturnBps;       // encrypted annual return
        euint16 benchmarkOutperformBps;// encrypted alpha vs benchmark
        uint256 lastRebalanceDate;
    }

    struct CoInvestmentDeal {
        uint256 portfolioId;
        address coInvestor;
        string dealRef;
        AssetClass assetClass;
        euint64 dealValueUSD;          // encrypted deal size
        euint64 swfShareBps;           // encrypted SWF share
        euint64 coInvestorShareBps;    // encrypted co-investor share
        euint16 expectedIRRBps;        // encrypted expected IRR
        uint256 committedAt;
    }

    mapping(uint256 => PortfolioAllocation) private portfolios;
    mapping(uint256 => CoInvestmentDeal) private deals;
    mapping(address => bool) public isBoardMember;

    uint256 public portfolioCount;
    uint256 public dealCount;
    euint64 private _totalGlobalSWFAUM;

    event PortfolioCreated(uint256 indexed id, string fundName);
    event PortfolioRebalanced(uint256 indexed id, uint256 rebalancedAt);
    event CoInvestmentCommitted(uint256 indexed dealId, uint256 portfolioId);

    modifier onlyBoardMember() {
        require(isBoardMember[msg.sender] || msg.sender == owner(), "Not board member");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalGlobalSWFAUM = FHE.asEuint64(0);
        FHE.allowThis(_totalGlobalSWFAUM);
        isBoardMember[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addBoardMember(address m) external onlyOwner { isBoardMember[m] = true; }

    function createPortfolio(
        string calldata fundName, string calldata sovereignEntity, GovernanceType govType,
        externalEuint64 encAUM, bytes calldata aumProof,
        externalEuint64 encCashReserve, bytes calldata crProof,
        externalEuint16 encReturn, bytes calldata retProof
    ) external onlyBoardMember whenNotPaused returns (uint256 id) {
        euint64 aum = FHE.fromExternal(encAUM, aumProof);
        euint64 cashReserve = FHE.fromExternal(encCashReserve, crProof);
        euint16 annReturn = FHE.fromExternal(encReturn, retProof);
        id = portfolioCount++;
        PortfolioAllocation storage _s0 = portfolios[id];
        _s0.fundName = fundName;
        _s0.sovereignEntity = sovereignEntity;
        _s0.govType = govType;
        _s0.totalAUMUSD = aum;
        _s0.publicEquityUSD = FHE.asEuint64(0);
        _s0.fixedIncomeUSD = FHE.asEuint64(0);
        _s0.alternativesUSD = FHE.asEuint64(0);
        _s0.infrastructureUSD = FHE.asEuint64(0);
        _s0.realEstateUSD = FHE.asEuint64(0);
        _s0.cashReserveUSD = cashReserve;
        _s0.annualReturnBps = annReturn;
        _s0.benchmarkOutperformBps = FHE.asEuint16(0);
        _s0.lastRebalanceDate = block.timestamp;
        _totalGlobalSWFAUM = FHE.add(_totalGlobalSWFAUM, aum);
        FHE.allowThis(portfolios[id].totalAUMUSD); FHE.allow(portfolios[id].totalAUMUSD, msg.sender);
        FHE.allowThis(portfolios[id].cashReserveUSD); FHE.allow(portfolios[id].cashReserveUSD, msg.sender);
        FHE.allowThis(portfolios[id].annualReturnBps); FHE.allow(portfolios[id].annualReturnBps, msg.sender);
        FHE.allowThis(portfolios[id].benchmarkOutperformBps);
        FHE.allowThis(_totalGlobalSWFAUM);
        emit PortfolioCreated(id, fundName);
    }

    function rebalancePortfolio(
        uint256 portfolioId,
        externalEuint64 encEquity, bytes calldata eqProof,
        externalEuint64 encFixedIncome, bytes calldata fiProof,
        externalEuint64 encAlternatives, bytes calldata altProof,
        externalEuint64 encInfra, bytes calldata infProof,
        externalEuint64 encRealEstate, bytes calldata reProof,
        externalEuint16 encBenchmarkAlpha, bytes calldata baProof
    ) external onlyBoardMember {
        PortfolioAllocation storage p = portfolios[portfolioId];
        p.publicEquityUSD = FHE.fromExternal(encEquity, eqProof);
        p.fixedIncomeUSD = FHE.fromExternal(encFixedIncome, fiProof);
        p.alternativesUSD = FHE.fromExternal(encAlternatives, altProof);
        p.infrastructureUSD = FHE.fromExternal(encInfra, infProof);
        p.realEstateUSD = FHE.fromExternal(encRealEstate, reProof);
        p.benchmarkOutperformBps = FHE.fromExternal(encBenchmarkAlpha, baProof);
        p.lastRebalanceDate = block.timestamp;
        FHE.allowThis(p.publicEquityUSD); FHE.allow(p.publicEquityUSD, msg.sender);
        FHE.allowThis(p.fixedIncomeUSD); FHE.allow(p.fixedIncomeUSD, msg.sender);
        FHE.allowThis(p.alternativesUSD); FHE.allow(p.alternativesUSD, msg.sender);
        FHE.allowThis(p.infrastructureUSD); FHE.allow(p.infrastructureUSD, msg.sender);
        FHE.allowThis(p.realEstateUSD); FHE.allow(p.realEstateUSD, msg.sender);
        FHE.allowThis(p.benchmarkOutperformBps); FHE.allow(p.benchmarkOutperformBps, msg.sender);
        emit PortfolioRebalanced(portfolioId, block.timestamp);
    }

    function commitCoInvestment(
        uint256 portfolioId, address coInvestor, string calldata dealRef, AssetClass assetClass,
        externalEuint64 encDealValue, bytes calldata dvProof,
        externalEuint64 encSWFShare, bytes calldata ssProof,
        externalEuint64 encCoShare, bytes calldata csProof,
        externalEuint16 encIRR, bytes calldata irrProof
    ) external onlyBoardMember nonReentrant returns (uint256 dealId) {
        euint64 dealValue = FHE.fromExternal(encDealValue, dvProof);
        euint64 swfShare = FHE.fromExternal(encSWFShare, ssProof);
        euint64 coShare = FHE.fromExternal(encCoShare, csProof);
        euint16 irr = FHE.fromExternal(encIRR, irrProof);
        dealId = dealCount++;
        deals[dealId].portfolioId = portfolioId;
        deals[dealId].coInvestor = coInvestor;
        deals[dealId].dealRef = dealRef;
        deals[dealId].assetClass = assetClass;
        deals[dealId].dealValueUSD = dealValue;
        deals[dealId].swfShareBps = swfShare;
        deals[dealId].coInvestorShareBps = coShare;
        deals[dealId].expectedIRRBps = irr;
        deals[dealId].committedAt = block.timestamp;
        FHE.allowThis(deals[dealId].dealValueUSD); FHE.allow(deals[dealId].dealValueUSD, msg.sender); FHE.allow(deals[dealId].dealValueUSD, coInvestor);
        FHE.allowThis(deals[dealId].swfShareBps); FHE.allow(deals[dealId].swfShareBps, msg.sender);
        FHE.allowThis(deals[dealId].coInvestorShareBps); FHE.allow(deals[dealId].coInvestorShareBps, coInvestor);
        FHE.allowThis(deals[dealId].expectedIRRBps);
        emit CoInvestmentCommitted(dealId, portfolioId);
    }

    function allowGlobalStats(address viewer) external onlyOwner {
        FHE.allow(_totalGlobalSWFAUM, viewer);
    }
}
