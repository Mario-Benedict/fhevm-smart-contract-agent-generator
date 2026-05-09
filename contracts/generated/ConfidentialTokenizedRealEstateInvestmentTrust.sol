// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialTokenizedRealEstateInvestmentTrust
/// @notice Tokenized REIT with encrypted property valuations, rental income,
///         NAV per share, and distribution amounts. Investors hold encrypted share balances.
contract ConfidentialTokenizedRealEstateInvestmentTrust is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PropertyType { OFFICE, RETAIL, INDUSTRIAL, MULTIFAMILY, HOTEL, DATA_CENTER, HEALTHCARE_FACILITY }

    struct Property {
        string propertyName;
        string address_;
        PropertyType propType;
        euint64 appraisedValueUSD;    // encrypted appraisal
        euint64 annualRentalIncomeUSD;// encrypted NOI
        euint64 occupancyRateBps;     // encrypted occupancy %
        euint64 capRateBps;           // encrypted capitalization rate
        euint64 outstandingDebtUSD;   // encrypted mortgage balance
        euint32 netLeasableAreaSqft;  // encrypted NLA
        uint256 acquisitionDate;
        bool active;
    }

    struct InvestorHolding {
        euint64 sharesOwned;          // encrypted token balance
        euint64 costBasisPerShare;    // encrypted average cost
        euint64 unrealizedGainLoss;   // encrypted unrealized P&L
        euint64 distributionsReceived;// encrypted cumulative dividends
        euint32 holdingPeriodDays;    // encrypted duration
        bool accreditedInvestor;
    }

    mapping(uint256 => Property) private properties;
    mapping(address => InvestorHolding) private investors;
    mapping(address => bool) public isFundManager;
    uint256 public propertyCount;
    euint64 private _totalNAV;               // encrypted total NAV
    euint64 private _totalSharesOutstanding; // encrypted total shares
    euint64 private _navPerShare;            // encrypted NAV/share
    euint64 private _quarterlyDPS;           // encrypted distribution per share
    euint64 private _totalRentalIncome;      // encrypted annualized rent

    event PropertyAcquired(uint256 indexed propId, PropertyType pType);
    event SharesIssued(address indexed investor, uint256 amount);
    event DistributionDeclared(uint256 indexed period);
    event DistributionClaimed(address indexed investor);
    event NAVUpdated();

    constructor() Ownable(msg.sender) {
        _totalNAV = FHE.asEuint64(0);
        _totalSharesOutstanding = FHE.asEuint64(0);
        _navPerShare = FHE.asEuint64(0);
        _quarterlyDPS = FHE.asEuint64(0);
        _totalRentalIncome = FHE.asEuint64(0);
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_totalSharesOutstanding);
        FHE.allowThis(_navPerShare);
        FHE.allowThis(_quarterlyDPS);
        FHE.allowThis(_totalRentalIncome);
        isFundManager[msg.sender] = true;
    }

    function addFundManager(address fm) external onlyOwner { isFundManager[fm] = true; }

    function acquireProperty(
        string calldata name,
        string calldata addr,
        PropertyType pType,
        externalEuint64 encValue,    bytes calldata vProof,
        externalEuint64 encNOI,      bytes calldata noiProof,
        externalEuint64 encOccupancy,bytes calldata occProof,
        externalEuint64 encCapRate,  bytes calldata crProof,
        externalEuint64 encDebt,     bytes calldata dProof,
        externalEuint32 encNLA,      bytes calldata nlaProof
    ) external returns (uint256 propId) {
        require(isFundManager[msg.sender], "Not fund manager");
        euint64 value    = FHE.fromExternal(encValue, vProof);
        euint64 noi      = FHE.fromExternal(encNOI, noiProof);
        euint64 occupancy= FHE.fromExternal(encOccupancy, occProof);
        euint64 capRate  = FHE.fromExternal(encCapRate, crProof);
        euint64 debt     = FHE.fromExternal(encDebt, dProof);
        euint32 nla      = FHE.fromExternal(encNLA, nlaProof);
        propId = propertyCount++;
        properties[propId] = Property({
            propertyName: name, address_: addr, propType: pType,
            appraisedValueUSD: value, annualRentalIncomeUSD: noi,
            occupancyRateBps: occupancy, capRateBps: capRate,
            outstandingDebtUSD: debt, netLeasableAreaSqft: nla,
            acquisitionDate: block.timestamp, active: true
        });
        _totalNAV = FHE.add(_totalNAV, FHE.sub(value, debt));
        _totalRentalIncome = FHE.add(_totalRentalIncome, noi);
        FHE.allowThis(properties[propId].appraisedValueUSD);
        FHE.allowThis(properties[propId].annualRentalIncomeUSD);
        FHE.allow(properties[propId].annualRentalIncomeUSD, msg.sender);
        FHE.allowThis(properties[propId].occupancyRateBps);
        FHE.allowThis(properties[propId].capRateBps);
        FHE.allowThis(properties[propId].outstandingDebtUSD);
        FHE.allowThis(properties[propId].netLeasableAreaSqft);
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_totalRentalIncome);
        emit PropertyAcquired(propId, pType);
    }

    function issueShares(
        address investor,
        bool accredited,
        externalEuint64 encShares,   bytes calldata sProof,
        externalEuint64 encCostBasis, bytes calldata cbProof
    ) external nonReentrant {
        require(isFundManager[msg.sender], "Not fund manager");
        euint64 shares   = FHE.fromExternal(encShares, sProof);
        euint64 costBasis= FHE.fromExternal(encCostBasis, cbProof);
        if (!FHE.isInitialized(investors[investor].sharesOwned)) {
            investors[investor].sharesOwned = FHE.asEuint64(0);
            investors[investor].distributionsReceived = FHE.asEuint64(0);
            FHE.allowThis(investors[investor].sharesOwned);
            FHE.allowThis(investors[investor].distributionsReceived);
        }
        investors[investor].sharesOwned = FHE.add(investors[investor].sharesOwned, shares);
        investors[investor].costBasisPerShare = costBasis;
        investors[investor].accreditedInvestor = accredited;
        _totalSharesOutstanding = FHE.add(_totalSharesOutstanding, shares);
        FHE.allowThis(investors[investor].sharesOwned);
        FHE.allow(investors[investor].sharesOwned, investor);
        FHE.allowThis(investors[investor].costBasisPerShare);
        FHE.allow(investors[investor].costBasisPerShare, investor);
        FHE.allowThis(_totalSharesOutstanding);
        emit SharesIssued(investor, 0);
    }

    function updateNAV(externalEuint64 encNewNAV, bytes calldata proof, uint64 totalSharesPlaintext) external {
        require(isFundManager[msg.sender], "Not fund manager");
        euint64 newNAV = FHE.fromExternal(encNewNAV, proof);
        _totalNAV = newNAV;
        // NAV per share = totalNAV / totalShares (plaintext divisor)
        if (totalSharesPlaintext > 0) {
            _navPerShare = FHE.div(newNAV, totalSharesPlaintext);
        } else {
            _navPerShare = FHE.asEuint64(0);
        }
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_navPerShare);
        emit NAVUpdated();
    }

    function declareDistribution(externalEuint64 encDPS, bytes calldata proof) external {
        require(isFundManager[msg.sender], "Not fund manager");
        _quarterlyDPS = FHE.fromExternal(encDPS, proof);
        FHE.allowThis(_quarterlyDPS);
        emit DistributionDeclared(block.timestamp);
    }

    function claimDistribution() external nonReentrant {
        require(FHE.isInitialized(investors[msg.sender].sharesOwned), "Not investor");
        euint64 distribution = FHE.mul(investors[msg.sender].sharesOwned, _quarterlyDPS);
        investors[msg.sender].distributionsReceived = FHE.add(
            investors[msg.sender].distributionsReceived, distribution
        );
        FHE.allowThis(investors[msg.sender].distributionsReceived);
        FHE.allow(investors[msg.sender].distributionsReceived, msg.sender);
        emit DistributionClaimed(msg.sender);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalNAV, viewer);
        FHE.allow(_navPerShare, viewer);
        FHE.allow(_totalRentalIncome, viewer);
    }
}
