// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateVentureCapitalSPV
/// @notice A Special Purpose Vehicle (SPV) for VC investments where LP commitments,
///         portfolio company valuations, and carry calculations remain encrypted.
///         Enables private fundraising rounds without leaking deal terms.
contract PrivateVentureCapitalSPV is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LPCommitment {
        euint64 committedAmount;   // USD cents, encrypted
        euint64 calledAmount;      // amount already drawn
        euint64 distributedAmount; // total returned to LP
        euint32 carryShareBps;     // LP's carry entitlement (bps)
        bool admitted;
        uint256 admissionDate;
    }

    struct PortfolioCompany {
        euint64 investedAmount;
        euint64 currentFMV;        // fair market value
        euint32 ownershipBps;      // encrypted ownership percentage
        bool exited;
        uint256 entryDate;
    }

    mapping(address => LPCommitment) private lpData;
    mapping(uint8 => PortfolioCompany) private portfolio;
    address[] public lpList;
    uint8 public portfolioCount;

    euint64 private _totalCommitted;
    euint64 private _totalCalled;
    euint64 private _grossPortfolioFMV;
    euint64 private _carryPool;          // GP carry accumulated
    euint32 private _fundCarryBps;       // GP carry rate (e.g. 2000 = 20%)
    uint256 public fundCloseDate;
    uint256 public fundTermYears;

    event LPAdmitted(address indexed lp);
    event CapitalCalled(address indexed lp);
    event CompanyInvested(uint8 indexed companyId);
    event FMVUpdated(uint8 indexed companyId);
    event DistributionMade(address indexed lp);

    constructor(
        externalEuint32 encCarryBps, bytes memory carryProof,
        uint256 _fundTermYears
    ) Ownable(msg.sender) {
        _fundCarryBps = FHE.fromExternal(encCarryBps, carryProof);
        _totalCommitted = FHE.asEuint64(0);
        _totalCalled = FHE.asEuint64(0);
        _grossPortfolioFMV = FHE.asEuint64(0);
        _carryPool = FHE.asEuint64(0);
        fundCloseDate = block.timestamp;
        fundTermYears = _fundTermYears;
        FHE.allowThis(_fundCarryBps);
        FHE.allowThis(_totalCommitted);
        FHE.allowThis(_totalCalled);
        FHE.allowThis(_grossPortfolioFMV);
        FHE.allowThis(_carryPool);
    }

    function admitLP(
        address lp,
        externalEuint64 encCommitment, bytes calldata commProof,
        externalEuint32 encCarryShare, bytes calldata shareProof
    ) external onlyOwner {
        require(!lpData[lp].admitted, "Already admitted");
        lpData[lp].committedAmount = FHE.fromExternal(encCommitment, commProof);
        lpData[lp].carryShareBps = FHE.fromExternal(encCarryShare, shareProof);
        lpData[lp].calledAmount = FHE.asEuint64(0);
        lpData[lp].distributedAmount = FHE.asEuint64(0);
        lpData[lp].admitted = true;
        lpData[lp].admissionDate = block.timestamp;
        _totalCommitted = FHE.add(_totalCommitted, lpData[lp].committedAmount);
        FHE.allowThis(lpData[lp].committedAmount);
        FHE.allow(lpData[lp].committedAmount, lp);
        FHE.allowThis(lpData[lp].carryShareBps);
        FHE.allowThis(lpData[lp].calledAmount);
        FHE.allow(lpData[lp].calledAmount, lp);
        FHE.allowThis(lpData[lp].distributedAmount);
        FHE.allow(lpData[lp].distributedAmount, lp);
        FHE.allowThis(_totalCommitted);
        lpList.push(lp);
        emit LPAdmitted(lp);
    }

    function callCapital(
        address lp,
        externalEuint64 encCallAmount, bytes calldata proof
    ) external onlyOwner nonReentrant {
        require(lpData[lp].admitted, "LP not admitted");
        euint64 callAmt = FHE.fromExternal(encCallAmount, proof);
        euint64 remaining = FHE.sub(lpData[lp].committedAmount, lpData[lp].calledAmount);
        ebool hasCap = FHE.le(callAmt, remaining);
        euint64 actual = FHE.select(hasCap, callAmt, remaining);
        lpData[lp].calledAmount = FHE.add(lpData[lp].calledAmount, actual);
        _totalCalled = FHE.add(_totalCalled, actual);
        FHE.allowThis(lpData[lp].calledAmount);
        FHE.allow(lpData[lp].calledAmount, lp);
        FHE.allow(actual, lp);
        FHE.allowThis(_totalCalled);
        emit CapitalCalled(lp);
    }

    function investInCompany(
        externalEuint64 encAmount, bytes calldata amtProof,
        externalEuint32 encOwnership, bytes calldata ownProof
    ) external onlyOwner {
        uint8 id = portfolioCount++;
        portfolio[id].investedAmount = FHE.fromExternal(encAmount, amtProof);
        portfolio[id].currentFMV = portfolio[id].investedAmount;
        portfolio[id].ownershipBps = FHE.fromExternal(encOwnership, ownProof);
        portfolio[id].entryDate = block.timestamp;
        _grossPortfolioFMV = FHE.add(_grossPortfolioFMV, portfolio[id].investedAmount);
        FHE.allowThis(portfolio[id].investedAmount);
        FHE.allowThis(portfolio[id].currentFMV);
        FHE.allowThis(portfolio[id].ownershipBps);
        FHE.allowThis(_grossPortfolioFMV);
        emit CompanyInvested(id);
    }

    function updateCompanyFMV(
        uint8 companyId,
        externalEuint64 encNewFMV, bytes calldata proof
    ) external onlyOwner {
        require(companyId < portfolioCount, "Invalid company");
        euint64 oldFMV = portfolio[companyId].currentFMV;
        euint64 newFMV = FHE.fromExternal(encNewFMV, proof);
        portfolio[companyId].currentFMV = newFMV;
        // Update gross FMV: remove old, add new
        _grossPortfolioFMV = FHE.sub(_grossPortfolioFMV, oldFMV);
        _grossPortfolioFMV = FHE.add(_grossPortfolioFMV, newFMV);
        FHE.allowThis(portfolio[companyId].currentFMV);
        FHE.allowThis(_grossPortfolioFMV);
        emit FMVUpdated(companyId);
    }

    function distribute(
        address lp,
        externalEuint64 encDistribution, bytes calldata proof
    ) external onlyOwner nonReentrant {
        require(lpData[lp].admitted, "LP not admitted");
        euint64 dist = FHE.fromExternal(encDistribution, proof);
        // Compute GP carry portion
        euint64 carry = FHE.div(FHE.mul(dist, 0), 10000);
        euint64 netDist = FHE.sub(dist, carry);
        lpData[lp].distributedAmount = FHE.add(lpData[lp].distributedAmount, netDist);
        _carryPool = FHE.add(_carryPool, carry);
        FHE.allowThis(lpData[lp].distributedAmount);
        FHE.allow(lpData[lp].distributedAmount, lp);
        FHE.allow(netDist, lp);
        FHE.allowThis(_carryPool);
        FHE.allow(_carryPool, owner());
        emit DistributionMade(lp);
    }

    function allowLPData(address viewer) external {
        require(lpData[msg.sender].admitted || msg.sender == owner(), "Not LP");
        FHE.allow(lpData[msg.sender].committedAmount, viewer);
        FHE.allow(lpData[msg.sender].calledAmount, viewer);
        FHE.allow(lpData[msg.sender].distributedAmount, viewer);
    }

    function allowFundMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalCommitted, viewer);
        FHE.allow(_totalCalled, viewer);
        FHE.allow(_grossPortfolioFMV, viewer);
        FHE.allow(_carryPool, viewer);
    }
}
