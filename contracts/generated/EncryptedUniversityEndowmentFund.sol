// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedUniversityEndowmentFund
/// @notice University endowment management with encrypted asset allocation targets,
///         portfolio returns, spending rates, and grant distribution — complying
///         with UPMIFA while protecting donor anonymity.
contract EncryptedUniversityEndowmentFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AssetAllocation { US_EQUITY, INTL_EQUITY, FIXED_INCOME, REAL_ASSETS, HEDGE_FUNDS, PE_VC, CASH }
    enum GrantType { SCHOLARSHIP, RESEARCH, FACULTY_CHAIR, CAPITAL_PROJECT, UNRESTRICTED }

    struct EndowmentAccount {
        string fundName;
        string donorName;
        address donorAddress;
        GrantType grantType;
        euint64 principalUSD;          // encrypted endowed principal
        euint64 marketValueUSD;        // encrypted current market value
        euint64 annualSpendableUSD;    // encrypted 5% spending rule amount
        euint64 spentToDateUSD;        // encrypted grants disbursed
        euint64 investmentReturnUSD;   // encrypted YTD return
        euint32 targetSpendingBps;     // encrypted spending rate (bps)
        uint256 establishedDate;
        bool restricted;
        bool active;
    }

    struct AssetBucket {
        AssetAllocation allocType;
        euint64 marketValueUSD;        // encrypted bucket value
        euint64 targetAllocationBps;   // encrypted target weight (bps)
        euint64 actualAllocationBps;   // encrypted actual weight
        euint64 benchmarkReturnBps;    // encrypted benchmark
        euint64 actualReturnBps;       // encrypted actual return
        euint8  managerScore;          // encrypted manager quality 0-100
        bool active;
    }

    struct GrantDisbursement {
        uint256 accountId;
        address recipient;
        GrantType grantType;
        euint64 amount;                // encrypted disbursement
        euint64 remainingBudget;       // encrypted remaining this period
        uint256 disbursementDate;
        string purpose;
        bool approved;
    }

    mapping(uint256 => EndowmentAccount) private accounts;
    mapping(uint256 => AssetBucket) private buckets;
    mapping(uint256 => GrantDisbursement) private grants;
    mapping(address => bool) public isInvestmentCommittee;
    mapping(address => bool) public isTrustee;
    uint256 public accountCount;
    uint256 public bucketCount;
    uint256 public grantCount;
    euint64 private _totalEndowmentValue;
    euint64 private _totalGrantsDisbursed;
    euint64 private _portfolioReturnYTD;

    event AccountEstablished(uint256 indexed accountId, string fundName);
    event GrantDisbursed(uint256 indexed grantId, address recipient);
    event PortfolioRebalanced();
    event AnnualPayout(uint256 indexed accountId);

    constructor() Ownable(msg.sender) {
        _totalEndowmentValue = FHE.asEuint64(0);
        _totalGrantsDisbursed = FHE.asEuint64(0);
        _portfolioReturnYTD = FHE.asEuint64(0);
        FHE.allowThis(_totalEndowmentValue);
        FHE.allowThis(_totalGrantsDisbursed);
        FHE.allowThis(_portfolioReturnYTD);
        isInvestmentCommittee[msg.sender] = true;
        isTrustee[msg.sender] = true;
    }

    function addCommitteeMember(address m) external onlyOwner { isInvestmentCommittee[m] = true; }
    function addTrustee(address t) external onlyOwner { isTrustee[t] = true; }

    function establishEndowment(
        string calldata fundName,
        string calldata donorName,
        address donorAddr,
        GrantType grantType,
        externalEuint64 encPrincipal,   bytes calldata pProof,
        externalEuint32 encSpendBps,    bytes calldata spProof,
        bool restricted
    ) external returns (uint256 accountId) {
        require(isTrustee[msg.sender], "Not trustee");
        euint64 principal  = FHE.fromExternal(encPrincipal, pProof);
        euint32 spendBps   = FHE.fromExternal(encSpendBps, spProof);
        accountId = accountCount++;
        accounts[accountId] = EndowmentAccount({
            fundName: fundName,
            donorName: donorName,
            donorAddress: donorAddr,
            grantType: grantType,
            principalUSD: principal,
            marketValueUSD: principal,
            annualSpendableUSD: FHE.div(FHE.mul(principal, 0), 10000),
            spentToDateUSD: FHE.asEuint64(0),
            investmentReturnUSD: FHE.asEuint64(0),
            targetSpendingBps: FHE.asEuint32(0),
            establishedDate: block.timestamp,
            restricted: restricted,
            active: true
        });
        _totalEndowmentValue = FHE.add(_totalEndowmentValue, principal);
        FHE.allowThis(accounts[accountId].principalUSD);
        FHE.allow(accounts[accountId].principalUSD, donorAddr);
        FHE.allowThis(accounts[accountId].marketValueUSD);
        FHE.allowThis(accounts[accountId].annualSpendableUSD);
        FHE.allowThis(accounts[accountId].spentToDateUSD);
        FHE.allowThis(accounts[accountId].investmentReturnUSD);
        FHE.allowThis(accounts[accountId].targetSpendingBps);
        FHE.allowThis(_totalEndowmentValue);
        emit AccountEstablished(accountId, fundName);
    }

    function addAssetBucket(
        AssetAllocation allocType,
        externalEuint64 encValue,       bytes calldata vProof,
        externalEuint64 encTargetBps,   bytes calldata tbProof,
        externalEuint64 encBenchmark,   bytes calldata bmProof,
        externalEuint8  encManagerScore,bytes calldata msProof
    ) external returns (uint256 bucketId) {
        require(isInvestmentCommittee[msg.sender], "Not committee");
        euint64 value   = FHE.fromExternal(encValue, vProof);
        euint64 target  = FHE.fromExternal(encTargetBps, tbProof);
        euint64 bench   = FHE.fromExternal(encBenchmark, bmProof);
        euint8  manager = FHE.fromExternal(encManagerScore, msProof);
        bucketId = bucketCount++;
        buckets[bucketId] = AssetBucket({
            allocType: allocType,
            marketValueUSD: value,
            targetAllocationBps: target,
            actualAllocationBps: FHE.asEuint64(0),
            benchmarkReturnBps: bench,
            actualReturnBps: FHE.asEuint64(0),
            managerScore: manager,
            active: true
        });
        FHE.allowThis(buckets[bucketId].marketValueUSD);
        FHE.allowThis(buckets[bucketId].targetAllocationBps);
        FHE.allow(buckets[bucketId].targetAllocationBps, msg.sender);
        FHE.allowThis(buckets[bucketId].actualAllocationBps);
        FHE.allowThis(buckets[bucketId].benchmarkReturnBps);
        FHE.allowThis(buckets[bucketId].actualReturnBps);
        FHE.allowThis(buckets[bucketId].managerScore);
    }

    function updateBucketReturn(
        uint256 bucketId,
        externalEuint64 encReturn, bytes calldata proof
    ) external {
        require(isInvestmentCommittee[msg.sender], "Not committee");
        euint64 ret = FHE.fromExternal(encReturn, proof);
        buckets[bucketId].actualReturnBps = ret;
        _portfolioReturnYTD = FHE.add(_portfolioReturnYTD, ret);
        FHE.allowThis(buckets[bucketId].actualReturnBps);
        FHE.allowThis(_portfolioReturnYTD);
    }

    function disburseGrant(
        uint256 accountId,
        address recipient,
        string calldata purpose,
        externalEuint64 encAmount, bytes calldata proof
    ) external returns (uint256 grantId) {
        require(isTrustee[msg.sender], "Not trustee");
        require(accounts[accountId].active, "Account inactive");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinBudget = FHE.le(
            FHE.add(accounts[accountId].spentToDateUSD, amount),
            accounts[accountId].annualSpendableUSD
        );
        euint64 actualAmount = FHE.select(withinBudget, amount, FHE.asEuint64(0));
        grantId = grantCount++;
        grants[grantId] = GrantDisbursement({
            accountId: accountId,
            recipient: recipient,
            grantType: accounts[accountId].grantType,
            amount: actualAmount,
            remainingBudget: FHE.sub(accounts[accountId].annualSpendableUSD,
                FHE.add(accounts[accountId].spentToDateUSD, actualAmount)),
            disbursementDate: block.timestamp,
            purpose: purpose,
            approved: true
        });
        accounts[accountId].spentToDateUSD = FHE.add(accounts[accountId].spentToDateUSD, actualAmount);
        _totalGrantsDisbursed = FHE.add(_totalGrantsDisbursed, actualAmount);
        FHE.allowThis(grants[grantId].amount);
        FHE.allow(grants[grantId].amount, recipient);
        FHE.allowThis(grants[grantId].remainingBudget);
        FHE.allowThis(accounts[accountId].spentToDateUSD);
        FHE.allowThis(_totalGrantsDisbursed);
        emit GrantDisbursed(grantId, recipient);
    }

    function allowEndowmentView(uint256 accountId, address viewer) external {
        require(isTrustee[msg.sender] || accounts[accountId].donorAddress == msg.sender, "Unauthorized");
        FHE.allow(accounts[accountId].marketValueUSD, viewer);
        FHE.allow(accounts[accountId].annualSpendableUSD, viewer);
        FHE.allow(accounts[accountId].investmentReturnUSD, viewer);
    }

    function allowPortfolioView(address viewer) external onlyOwner {
        FHE.allow(_totalEndowmentValue, viewer);
        FHE.allow(_totalGrantsDisbursed, viewer);
        FHE.allow(_portfolioReturnYTD, viewer);
    }
}
