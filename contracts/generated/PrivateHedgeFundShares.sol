// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHedgeFundShares
/// @notice Hedge fund with encrypted NAV per share, encrypted investor allocations,
///         and quarterly redemptions gated by encrypted lock-up periods.
contract PrivateHedgeFundShares is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct InvestorAccount {
        euint64 sharesOwned;         // encrypted share count
        euint64 totalInvested;       // encrypted total capital invested
        euint64 unrealizedGain;      // encrypted unrealized P&L
        uint256 lockupUntil;
        bool accredited;
        bool active;
    }

    euint64 private _navPerShare;       // encrypted NAV per share (USD * 1e6)
    euint64 private _totalShares;       // encrypted total shares outstanding
    euint64 private _totalAUM;          // encrypted total assets under management
    euint64 private _performanceFeeBps; // encrypted performance fee
    euint64 private _managementFeeBps;  // encrypted management fee
    mapping(address => InvestorAccount) private investors;
    mapping(address => bool) public isFundAdmin;
    uint256 public quarterlyFeeDate;

    event InvestorAdded(address indexed investor);
    event CapitalDeployed(address indexed investor);
    event Redemption(address indexed investor);
    event NAVUpdated();
    event FeesCharged();

    constructor(
        externalEuint64 encInitialNAV, bytes memory navProof,
        externalEuint64 encPerfFee, bytes memory pfProof,
        externalEuint64 encMgmtFee, bytes memory mfProof
    ) Ownable(msg.sender) {
        _navPerShare = FHE.fromExternal(encInitialNAV, navProof);
        _performanceFeeBps = FHE.fromExternal(encPerfFee, pfProof);
        _managementFeeBps = FHE.fromExternal(encMgmtFee, mfProof);
        _totalShares = FHE.asEuint64(0);
        _totalAUM = FHE.asEuint64(0);
        FHE.allowThis(_navPerShare);
        FHE.allowThis(_performanceFeeBps);
        FHE.allowThis(_managementFeeBps);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAUM);
        isFundAdmin[msg.sender] = true;
        quarterlyFeeDate = block.timestamp + 90 days;
    }

    function addFundAdmin(address a) external onlyOwner { isFundAdmin[a] = true; }

    function onboardInvestor(address investor, uint256 lockupDays) external {
        require(isFundAdmin[msg.sender], "Not admin");
        investors[investor] = InvestorAccount({
            sharesOwned: FHE.asEuint64(0), totalInvested: FHE.asEuint64(0),
            unrealizedGain: FHE.asEuint64(0), lockupUntil: block.timestamp + lockupDays * 1 days,
            accredited: true, active: true
        });
        FHE.allowThis(investors[investor].sharesOwned);
        FHE.allow(investors[investor].sharesOwned, investor);
        FHE.allowThis(investors[investor].totalInvested);
        FHE.allow(investors[investor].totalInvested, investor);
        FHE.allowThis(investors[investor].unrealizedGain);
        FHE.allow(investors[investor].unrealizedGain, investor);
        emit InvestorAdded(investor);
    }

    function invest(externalEuint64 encCapital, bytes calldata proof) external nonReentrant {
        InvestorAccount storage inv = investors[msg.sender];
        require(inv.accredited && inv.active, "Not eligible");
        euint64 capital = FHE.fromExternal(encCapital, proof);
        // Shares = capital / NAV
        euint64 sharesToIssue = FHE.div(capital, uint64(1)); // simplified: 1 unit NAV
        inv.sharesOwned = FHE.add(inv.sharesOwned, sharesToIssue);
        inv.totalInvested = FHE.add(inv.totalInvested, capital);
        _totalShares = FHE.add(_totalShares, sharesToIssue);
        _totalAUM = FHE.add(_totalAUM, capital);
        FHE.allowThis(inv.sharesOwned);
        FHE.allow(inv.sharesOwned, msg.sender);
        FHE.allowThis(inv.totalInvested);
        FHE.allow(inv.totalInvested, msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAUM);
        emit CapitalDeployed(msg.sender);
    }

    function requestRedemption(externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        InvestorAccount storage inv = investors[msg.sender];
        require(inv.active && block.timestamp >= inv.lockupUntil, "Locked");
        euint64 shares = FHE.fromExternal(encShares, proof);
        ebool hasSufficientShares = FHE.le(shares, inv.sharesOwned);
        euint64 actualShares = FHE.select(hasSufficientShares, shares, inv.sharesOwned);
        euint64 redemptionValue = FHE.mul(actualShares, _navPerShare);
        inv.sharesOwned = FHE.sub(inv.sharesOwned, actualShares);
        _totalShares = FHE.sub(_totalShares, actualShares);
        _totalAUM = FHE.sub(_totalAUM, redemptionValue);
        FHE.allowThis(inv.sharesOwned);
        FHE.allow(inv.sharesOwned, msg.sender);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_totalAUM);
        FHE.allow(redemptionValue, msg.sender);
        emit Redemption(msg.sender);
    }

    function updateNAV(externalEuint64 encNewNAV, bytes calldata proof) external {
        require(isFundAdmin[msg.sender], "Not admin");
        _navPerShare = FHE.fromExternal(encNewNAV, proof);
        FHE.allowThis(_navPerShare);
        emit NAVUpdated();
    }

    function chargeManagementFee() external {
        require(isFundAdmin[msg.sender] && block.timestamp >= quarterlyFeeDate, "Not time");
        euint64 fee = FHE.div(FHE.mul(_totalAUM, _managementFeeBps), 10000);
        _totalAUM = FHE.sub(_totalAUM, fee);
        quarterlyFeeDate = block.timestamp + 90 days;
        FHE.allowThis(_totalAUM);
        FHE.allow(fee, owner());
        emit FeesCharged();
    }

    function allowFundStats(address viewer) external {
        require(isFundAdmin[msg.sender], "Not admin");
        FHE.allow(_navPerShare, viewer);
        FHE.allow(_totalAUM, viewer);
        FHE.allow(_totalShares, viewer);
    }

    function allowInvestorData(address investor, address viewer) external {
        require(isFundAdmin[msg.sender] || msg.sender == investor, "Unauthorized");
        FHE.allow(investors[investor].sharesOwned, viewer);
        FHE.allow(investors[investor].totalInvested, viewer);
        FHE.allow(investors[investor].unrealizedGain, viewer);
    }
}
