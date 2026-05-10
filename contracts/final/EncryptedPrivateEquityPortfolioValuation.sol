// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateEquityPortfolioValuation
/// @notice Private equity portfolio with encrypted company valuations,
///         MOIC/IRR metrics, exit multiples, and co-investor allocations.
contract EncryptedPrivateEquityPortfolioValuation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InvestmentStage { SEED, SERIES_A, SERIES_B, SERIES_C, GROWTH, PRE_IPO }
    enum ExitType { IPO, STRATEGIC_SALE, SECONDARY, RECAPITALIZATION, WRITE_OFF }

    struct PortfolioCompany {
        string companyName;
        string industry;
        InvestmentStage stage;
        address leadInvestor;
        euint64 investmentCostUSD;     // encrypted cost basis
        euint64 currentFMVUSD;         // encrypted fair market value
        euint64 revenueAnnualUSD;      // encrypted ARR
        euint64 ebitdaUSD;             // encrypted EBITDA
        euint64 evMultipleBps;         // encrypted EV/EBITDA multiple (bps)
        euint64 ownershipPctBps;       // encrypted ownership stake (bps)
        euint64 moicBps;               // encrypted MOIC (bps, 10000=1.0x)
        euint8  irrPct;                // encrypted IRR %
        uint256 investmentDate;
        ExitType exitType;
        bool exited;
    }

    struct CoInvestor {
        euint64 investmentUSD;         // encrypted co-invest amount
        euint64 ownershipBps;          // encrypted co-invest stake
        euint64 currentValueUSD;       // encrypted mark-to-market value
        bool active;
    }

    mapping(uint256 => PortfolioCompany) private companies;
    mapping(uint256 => mapping(address => CoInvestor)) private coInvestors;
    mapping(address => bool) public isPortfolioManager;
    uint256 public companyCount;
    euint64 private _totalFundNAV;
    euint64 private _totalCostBasis;
    euint64 private _totalUnrealizedGain;
    euint64 private _totalRealizedGain;

    event CompanyAdded(uint256 indexed companyId, string name, InvestmentStage stage);
    event ValuationUpdated(uint256 indexed companyId);
    event CompanyExited(uint256 indexed companyId, ExitType exitType);
    event CoInvestorAdded(uint256 indexed companyId, address coInvestor);

    constructor() Ownable(msg.sender) {
        _totalFundNAV = FHE.asEuint64(0);
        _totalCostBasis = FHE.asEuint64(0);
        _totalUnrealizedGain = FHE.asEuint64(0);
        _totalRealizedGain = FHE.asEuint64(0);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalCostBasis);
        FHE.allowThis(_totalUnrealizedGain);
        FHE.allowThis(_totalRealizedGain);
        isPortfolioManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isPortfolioManager[m] = true; }

    function addPortfolioCompany(
        string calldata name, string calldata industry, InvestmentStage stage,
        externalEuint64 encCost,     bytes calldata cProof,
        externalEuint64 encFMV,      bytes calldata fProof,
        externalEuint64 encRevenue,  bytes calldata rProof,
        externalEuint64 encEBITDA,   bytes calldata eProof,
        externalEuint64 encOwnership,bytes calldata oProof,
        externalEuint64 encMOIC,     bytes calldata mProof,
        externalEuint8  encIRR,      bytes calldata irrProof
    ) external returns (uint256 companyId) {
        require(isPortfolioManager[msg.sender], "Not manager");
        euint64 cost     = FHE.fromExternal(encCost, cProof);
        euint64 fmv      = FHE.fromExternal(encFMV, fProof);
        euint64 revenue  = FHE.fromExternal(encRevenue, rProof);
        euint64 ebitda   = FHE.fromExternal(encEBITDA, eProof);
        euint64 ownership= FHE.fromExternal(encOwnership, oProof);
        euint64 moic     = FHE.fromExternal(encMOIC, mProof);
        euint8  irr      = FHE.fromExternal(encIRR, irrProof);
        companyId = companyCount++;
        PortfolioCompany storage _s0 = companies[companyId];
        _s0.companyName = name;
        _s0.industry = industry;
        _s0.stage = stage;
        _s0.leadInvestor = msg.sender;
        _s0.investmentCostUSD = cost;
        _s0.currentFMVUSD = fmv;
        _s0.revenueAnnualUSD = revenue;
        _s0.ebitdaUSD = ebitda;
        _s0.evMultipleBps = FHE.asEuint64(0);
        _s0.ownershipPctBps = ownership;
        _s0.moicBps = moic;
        _s0.irrPct = irr;
        _s0.investmentDate = block.timestamp;
        _s0.exitType = ExitType.STRATEGIC_SALE;
        _s0.exited = false;
        _totalCostBasis = FHE.add(_totalCostBasis, cost);
        _totalFundNAV = FHE.add(_totalFundNAV, fmv);
        euint64 unrealized = FHE.sub(fmv, cost);
        _totalUnrealizedGain = FHE.add(_totalUnrealizedGain, unrealized);
        FHE.allowThis(companies[companyId].investmentCostUSD);
        FHE.allow(companies[companyId].investmentCostUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFundNAV, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCostBasis, msg.sender); // [acl_misconfig]
        FHE.allowThis(companies[companyId].currentFMVUSD);
        FHE.allow(companies[companyId].currentFMVUSD, msg.sender);
        FHE.allowThis(companies[companyId].revenueAnnualUSD);
        FHE.allow(companies[companyId].revenueAnnualUSD, msg.sender);
        FHE.allowThis(companies[companyId].ebitdaUSD);
        FHE.allow(companies[companyId].ebitdaUSD, msg.sender);
        FHE.allowThis(companies[companyId].ownershipPctBps);
        FHE.allow(companies[companyId].ownershipPctBps, msg.sender);
        FHE.allowThis(companies[companyId].moicBps);
        FHE.allow(companies[companyId].moicBps, msg.sender);
        FHE.allowThis(companies[companyId].irrPct);
        FHE.allow(companies[companyId].irrPct, msg.sender);
        FHE.allowThis(companies[companyId].evMultipleBps);
        FHE.allowThis(_totalCostBasis);
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(_totalUnrealizedGain);
        emit CompanyAdded(companyId, name, stage);
    }

    function updateValuation(
        uint256 companyId,
        externalEuint64 encNewFMV, bytes calldata proof
    ) external {
        require(isPortfolioManager[msg.sender], "Not manager");
        euint64 oldFMV = companies[companyId].currentFMVUSD;
        euint64 newFMV = FHE.fromExternal(encNewFMV, proof);
        _totalFundNAV = FHE.sub(_totalFundNAV, oldFMV);
        _totalFundNAV = FHE.add(_totalFundNAV, newFMV);
        companies[companyId].currentFMVUSD = newFMV;
        companies[companyId].moicBps = FHE.mul(newFMV, FHE.asEuint64(10000)); // simplified: cost divisor omitted
        FHE.allowThis(companies[companyId].currentFMVUSD);
        FHE.allow(companies[companyId].currentFMVUSD, companies[companyId].leadInvestor);
        FHE.allowThis(companies[companyId].moicBps);
        FHE.allowThis(_totalFundNAV);
        emit ValuationUpdated(companyId);
    }

    function recordExit(uint256 companyId, ExitType exitType, externalEuint64 encExitProceeds, bytes calldata proof) external {
        require(isPortfolioManager[msg.sender], "Not manager");
        euint64 proceeds = FHE.fromExternal(encExitProceeds, proof);
        euint64 realizedGain = FHE.sub(proceeds, companies[companyId].investmentCostUSD);
        _totalRealizedGain = FHE.add(_totalRealizedGain, realizedGain);
        _totalFundNAV = FHE.sub(_totalFundNAV, companies[companyId].currentFMVUSD);
        companies[companyId].exited = true;
        companies[companyId].exitType = exitType;
        FHE.allowThis(_totalRealizedGain);
        FHE.allowThis(_totalFundNAV);
        emit CompanyExited(companyId, exitType);
    }

    function addCoInvestor(
        uint256 companyId, address coInvestor,
        externalEuint64 encInvestment, bytes calldata invProof,
        externalEuint64 encOwnership,  bytes calldata ownProof
    ) external {
        require(isPortfolioManager[msg.sender], "Not manager");
        euint64 investment = FHE.fromExternal(encInvestment, invProof);
        euint64 ownership  = FHE.fromExternal(encOwnership, ownProof);
        coInvestors[companyId][coInvestor] = CoInvestor({
            investmentUSD: investment, ownershipBps: ownership,
            currentValueUSD: investment, active: true
        });
        FHE.allowThis(coInvestors[companyId][coInvestor].investmentUSD);
        FHE.allow(coInvestors[companyId][coInvestor].investmentUSD, coInvestor);
        FHE.allowThis(coInvestors[companyId][coInvestor].ownershipBps);
        FHE.allow(coInvestors[companyId][coInvestor].ownershipBps, coInvestor);
        FHE.allowThis(coInvestors[companyId][coInvestor].currentValueUSD);
        FHE.allow(coInvestors[companyId][coInvestor].currentValueUSD, coInvestor);
        emit CoInvestorAdded(companyId, coInvestor);
    }

    function allowFundView(address viewer) external onlyOwner {
        FHE.allow(_totalFundNAV, viewer);
        FHE.allow(_totalCostBasis, viewer);
        FHE.allow(_totalUnrealizedGain, viewer);
        FHE.allow(_totalRealizedGain, viewer);
    }
}
