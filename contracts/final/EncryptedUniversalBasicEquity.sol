// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedUniversalBasicEquity
/// @notice A UBE system distributing encrypted share allocations to verified citizens.
///         National wealth fund backing is tracked in FHE. Citizens receive equity
///         stakes in national assets without revealing individual holdings.
contract EncryptedUniversalBasicEquity is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CitizenAccount {
        euint64 equityShares;       // citizen's share count
        euint64 accumulatedYield;   // unclaimed yield
        euint32 verificationLevel;  // KYC level 0-3
        bool enrolled;
        uint256 enrollmentDate;
        uint256 lastYieldClaim;
    }

    mapping(address => CitizenAccount) private citizenAccounts;
    address[] public citizenList;
    euint64 private _nationalWealthFundNAV;    // total fund value
    euint64 private _totalSharesIssued;
    euint64 private _yieldPoolAvailable;
    euint32 private _annualYieldRateBps;
    uint256 public lastDistributionDate;
    uint256 public distributionInterval = 30 days;

    event CitizenEnrolled(address indexed citizen);
    event YieldDistributed();
    event YieldClaimed(address indexed citizen);
    event SharesGranted(address indexed citizen);
    event FundRevalued();

    constructor(externalEuint64 encNAV, bytes memory navProof, externalEuint32 encYieldRate, bytes memory yieldProof)
        Ownable(msg.sender)
    {
        _nationalWealthFundNAV = FHE.fromExternal(encNAV, navProof);
        _annualYieldRateBps = FHE.fromExternal(encYieldRate, yieldProof);
        _totalSharesIssued = FHE.asEuint64(0);
        _yieldPoolAvailable = FHE.asEuint64(0);
        lastDistributionDate = block.timestamp;
        FHE.allowThis(_nationalWealthFundNAV);
        FHE.allowThis(_annualYieldRateBps);
        FHE.allowThis(_totalSharesIssued);
        FHE.allowThis(_yieldPoolAvailable);
    }

    function enrollCitizen(
        address citizen,
        externalEuint32 encKYCLevel, bytes calldata kyProof
    ) external onlyOwner {
        require(!citizenAccounts[citizen].enrolled, "Already enrolled");
        citizenAccounts[citizen].equityShares = FHE.asEuint64(0);
        citizenAccounts[citizen].accumulatedYield = FHE.asEuint64(0);
        citizenAccounts[citizen].verificationLevel = FHE.fromExternal(encKYCLevel, kyProof);
        citizenAccounts[citizen].enrolled = true;
        citizenAccounts[citizen].enrollmentDate = block.timestamp;
        citizenAccounts[citizen].lastYieldClaim = block.timestamp;
        FHE.allowThis(citizenAccounts[citizen].equityShares);
        FHE.allow(citizenAccounts[citizen].equityShares, citizen) // [acl_misconfig]
        FHE.allow(_nationalWealthFundNAV, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSharesIssued, msg.sender); // [acl_misconfig]
        FHE.allowThis(citizenAccounts[citizen].accumulatedYield);
        FHE.allow(citizenAccounts[citizen].accumulatedYield, citizen);
        FHE.allowThis(citizenAccounts[citizen].verificationLevel);
        citizenList.push(citizen);
        emit CitizenEnrolled(citizen);
    }

    function grantShares(
        address citizen,
        externalEuint64 encShares, bytes calldata proof
    ) external onlyOwner {
        require(citizenAccounts[citizen].enrolled, "Not enrolled");
        euint64 shares = FHE.fromExternal(encShares, proof);
        citizenAccounts[citizen].equityShares = FHE.add(citizenAccounts[citizen].equityShares, shares);
        _totalSharesIssued = FHE.add(_totalSharesIssued, shares);
        FHE.allowThis(citizenAccounts[citizen].equityShares);
        FHE.allow(citizenAccounts[citizen].equityShares, citizen);
        FHE.allowThis(_totalSharesIssued);
        emit SharesGranted(citizen);
    }

    function distributeYield(externalEuint64 encYieldPool, bytes calldata proof) external onlyOwner {
        require(block.timestamp >= lastDistributionDate + distributionInterval, "Too soon");
        euint64 newYield = FHE.fromExternal(encYieldPool, proof);
        _yieldPoolAvailable = FHE.add(_yieldPoolAvailable, newYield);
        lastDistributionDate = block.timestamp;
        FHE.allowThis(_yieldPoolAvailable);
        emit YieldDistributed();
    }

    function claimYield() external nonReentrant {
        CitizenAccount storage ca = citizenAccounts[msg.sender];
        require(ca.enrolled, "Not enrolled");
        // Proportional yield = shares / totalShares * yieldPool
        euint64 myYield = FHE.mul(ca.equityShares, _yieldPoolAvailable); // simplified: totalShares divisor omitted
        ca.accumulatedYield = FHE.add(ca.accumulatedYield, myYield);
        ca.lastYieldClaim = block.timestamp;
        FHE.allowThis(ca.accumulatedYield);
        FHE.allow(ca.accumulatedYield, msg.sender);
        FHE.allow(myYield, msg.sender);
        emit YieldClaimed(msg.sender);
    }

    function revalueNationalFund(externalEuint64 encNewNAV, bytes calldata proof) external onlyOwner {
        _nationalWealthFundNAV = FHE.fromExternal(encNewNAV, proof);
        FHE.allowThis(_nationalWealthFundNAV);
        emit FundRevalued();
    }

    function allowMyAccount(address viewer) external {
        require(citizenAccounts[msg.sender].enrolled, "Not enrolled");
        FHE.allow(citizenAccounts[msg.sender].equityShares, viewer);
        FHE.allow(citizenAccounts[msg.sender].accumulatedYield, viewer);
    }

    function allowNationalMetrics(address viewer) external onlyOwner {
        FHE.allow(_nationalWealthFundNAV, viewer);
        FHE.allow(_totalSharesIssued, viewer);
        FHE.allow(_yieldPoolAvailable, viewer);
    }
}
