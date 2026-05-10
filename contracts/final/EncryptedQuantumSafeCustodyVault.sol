// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedQuantumSafeCustodyVault
/// @notice Institutional digital asset custody with encrypted holdings balances,
///         encrypted withdrawal limits, multi-party authorization thresholds,
///         and quantum-safe key rotation flags tracked on-chain.
contract EncryptedQuantumSafeCustodyVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetClass { BITCOIN, ETHEREUM, STABLECOIN, TOKENIZED_SECURITY, NFT_BASKET }
    enum AuthorizationTier { SINGLE_SIGN, DUAL_CONTROL, QUORUM_3OF5, BOARD_MAJORITY }

    struct AssetHolding {
        AssetClass assetClass;
        string ticker;
        euint64 custodiedAmount;     // encrypted total custody balance
        euint64 availableForWithdraw;// encrypted amount available
        euint64 stakedAmount;        // encrypted staked portion
        euint64 dailyWithdrawLimit;  // encrypted daily withdrawal cap
        euint64 withdrawnToday;      // encrypted amount withdrawn today
        euint32 custodyFeesBps;      // encrypted annual custody fee
        uint256 lastFeeCollection;
        bool quantumKeyRotated;
    }

    struct ClientAccount {
        string clientName;
        AuthorizationTier authTier;
        euint64 totalAUM;            // encrypted total assets under custody
        euint64 accruedFees;         // encrypted unpaid custody fees
        euint32 riskScore;           // encrypted risk classification
        euint8  kycLevel;            // encrypted KYC tier 1-5
        uint256 onboardDate;
        bool active;
        bool sanctionsCleared;
    }

    struct WithdrawalRequest {
        address client;
        uint256 holdingId;
        euint64 amount;              // encrypted requested amount
        uint256 requestTimestamp;
        uint256 executionTimestamp;
        uint256 approvalCount;
        bool executed;
        bool cancelled;
    }

    mapping(uint256 => AssetHolding) private holdings;
    mapping(address => ClientAccount) private clients;
    mapping(address => mapping(uint256 => bool)) private clientHoldings;
    mapping(uint256 => WithdrawalRequest) private withdrawalRequests;
    mapping(uint256 => mapping(address => bool)) private requestApprovals;
    mapping(address => bool) public isAuthorizer;
    mapping(address => bool) public isCompliance;
    uint256 public holdingCount;
    uint256 public withdrawalRequestCount;
    euint64 private _totalVaultAUM;
    euint64 private _totalFeesCollected;

    event HoldingCreated(uint256 indexed holdingId, AssetClass assetClass, string ticker);
    event ClientOnboarded(address indexed client);
    event DepositRecorded(address indexed client, uint256 indexed holdingId);
    event WithdrawalRequested(uint256 indexed reqId, address indexed client);
    event WithdrawalApproved(uint256 indexed reqId, address indexed approver);
    event WithdrawalExecuted(uint256 indexed reqId);
    event FeesCollected(address indexed client);
    event QuantumKeyRotated(uint256 indexed holdingId);

    constructor() Ownable(msg.sender) {
        _totalVaultAUM = FHE.asEuint64(0);
        _totalFeesCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalVaultAUM);
        FHE.allowThis(_totalFeesCollected);
        isAuthorizer[msg.sender] = true;
        isCompliance[msg.sender] = true;
    }

    function addAuthorizer(address auth) external onlyOwner { isAuthorizer[auth] = true; }
    function addCompliance(address comp) external onlyOwner { isCompliance[comp] = true; }

    function onboardClient(
        address client,
        string calldata name,
        AuthorizationTier tier,
        externalEuint32 encRisk, bytes calldata rProof,
        externalEuint8  encKYC,  bytes calldata kProof
    ) external {
        require(isCompliance[msg.sender], "Not compliance");
        euint32 risk = FHE.fromExternal(encRisk, rProof);
        euint8  kyc  = FHE.fromExternal(encKYC, kProof);
        clients[client].clientName = name;
        clients[client].authTier = tier;
        clients[client].totalAUM = FHE.asEuint64(0);
        clients[client].accruedFees = FHE.asEuint64(0);
        clients[client].riskScore = risk;
        clients[client].kycLevel = kyc;
        clients[client].onboardDate = block.timestamp;
        clients[client].active = true;
        clients[client].sanctionsCleared = true;
        FHE.allowThis(clients[client].totalAUM);
        FHE.allow(clients[client].totalAUM, client) // [acl_misconfig]
        FHE.allow(_totalVaultAUM, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFeesCollected, msg.sender); // [acl_misconfig]
        FHE.allowThis(clients[client].accruedFees);
        FHE.allowThis(clients[client].riskScore);
        FHE.allowThis(clients[client].kycLevel);
        emit ClientOnboarded(client);
    }

    function createHolding(
        AssetClass assetClass,
        string calldata ticker,
        externalEuint32 encFeeBps,  bytes calldata fProof,
        externalEuint64 encDailyLimit, bytes calldata dlProof
    ) external onlyOwner returns (uint256 holdId) {
        euint32 feeBps   = FHE.fromExternal(encFeeBps, fProof);
        euint64 dayLimit = FHE.fromExternal(encDailyLimit, dlProof);
        holdId = holdingCount++;
        holdings[holdId].assetClass = assetClass;
        holdings[holdId].ticker = ticker;
        holdings[holdId].custodiedAmount = FHE.asEuint64(0);
        holdings[holdId].availableForWithdraw = FHE.asEuint64(0);
        holdings[holdId].stakedAmount = FHE.asEuint64(0);
        holdings[holdId].dailyWithdrawLimit = dayLimit;
        holdings[holdId].withdrawnToday = FHE.asEuint64(0);
        holdings[holdId].custodyFeesBps = FHE.asEuint32(0);
        holdings[holdId].lastFeeCollection = block.timestamp;
        holdings[holdId].quantumKeyRotated = false;
        FHE.allowThis(holdings[holdId].custodiedAmount);
        FHE.allowThis(holdings[holdId].availableForWithdraw);
        FHE.allowThis(holdings[holdId].stakedAmount);
        FHE.allowThis(holdings[holdId].dailyWithdrawLimit);
        FHE.allowThis(holdings[holdId].withdrawnToday);
        FHE.allowThis(holdings[holdId].custodyFeesBps);
        emit HoldingCreated(holdId, assetClass, ticker);
    }

    function recordDeposit(
        address client,
        uint256 holdingId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        require(isAuthorizer[msg.sender], "Not authorizer");
        require(clients[client].active, "Client not active");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        holdings[holdingId].custodiedAmount = FHE.add(holdings[holdingId].custodiedAmount, amount);
        holdings[holdingId].availableForWithdraw = FHE.add(holdings[holdingId].availableForWithdraw, amount);
        clients[client].totalAUM = FHE.add(clients[client].totalAUM, amount);
        _totalVaultAUM = FHE.add(_totalVaultAUM, amount);
        clientHoldings[client][holdingId] = true;
        FHE.allowThis(holdings[holdingId].custodiedAmount);
        FHE.allowThis(holdings[holdingId].availableForWithdraw);
        FHE.allowThis(clients[client].totalAUM);
        FHE.allow(clients[client].totalAUM, client);
        FHE.allowThis(_totalVaultAUM);
        emit DepositRecorded(client, holdingId);
    }

    function requestWithdrawal(
        uint256 holdingId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant whenNotPaused returns (uint256 reqId) {
        require(clients[msg.sender].active, "Client not active");
        require(clientHoldings[msg.sender][holdingId], "No holding");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinLimit = FHE.le(amount, holdings[holdingId].dailyWithdrawLimit);
        euint64 reqAmount = FHE.select(withinLimit, amount, holdings[holdingId].dailyWithdrawLimit);
        reqId = withdrawalRequestCount++;
        withdrawalRequests[reqId] = WithdrawalRequest({
            client: msg.sender,
            holdingId: holdingId,
            amount: reqAmount,
            requestTimestamp: block.timestamp,
            executionTimestamp: 0,
            approvalCount: 0,
            executed: false,
            cancelled: false
        });
        FHE.allowThis(withdrawalRequests[reqId].amount);
        FHE.allow(withdrawalRequests[reqId].amount, msg.sender);
        emit WithdrawalRequested(reqId, msg.sender);
    }

    function approveWithdrawal(uint256 reqId) external {
        require(isAuthorizer[msg.sender], "Not authorizer");
        require(!requestApprovals[reqId][msg.sender], "Already approved");
        requestApprovals[reqId][msg.sender] = true;
        withdrawalRequests[reqId].approvalCount++;
        emit WithdrawalApproved(reqId, msg.sender);
        uint256 required = clients[withdrawalRequests[reqId].client].authTier == AuthorizationTier.SINGLE_SIGN ? 1 : 2;
        if (withdrawalRequests[reqId].approvalCount >= required) {
            _executeWithdrawal(reqId);
        }
    }

    function _executeWithdrawal(uint256 reqId) internal {
        WithdrawalRequest storage req = withdrawalRequests[reqId];
        require(!req.executed, "Already executed");
        holdings[req.holdingId].availableForWithdraw = FHE.sub(
            holdings[req.holdingId].availableForWithdraw, req.amount
        );
        holdings[req.holdingId].custodiedAmount = FHE.sub(
            holdings[req.holdingId].custodiedAmount, req.amount
        );
        holdings[req.holdingId].withdrawnToday = FHE.add(
            holdings[req.holdingId].withdrawnToday, req.amount
        );
        clients[req.client].totalAUM = FHE.sub(clients[req.client].totalAUM, req.amount);
        _totalVaultAUM = FHE.sub(_totalVaultAUM, req.amount);
        req.executed = true;
        req.executionTimestamp = block.timestamp;
        FHE.allowThis(holdings[req.holdingId].availableForWithdraw);
        FHE.allowThis(holdings[req.holdingId].custodiedAmount);
        FHE.allowThis(holdings[req.holdingId].withdrawnToday);
        FHE.allowThis(clients[req.client].totalAUM);
        FHE.allowThis(_totalVaultAUM);
        emit WithdrawalExecuted(reqId);
    }

    function rotateQuantumKey(uint256 holdingId) external onlyOwner {
        holdings[holdingId].quantumKeyRotated = true;
        emit QuantumKeyRotated(holdingId);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowClientView(address client, address viewer) external onlyOwner {
        FHE.allow(clients[client].totalAUM, viewer);
        FHE.allow(clients[client].riskScore, viewer);
    }
}
