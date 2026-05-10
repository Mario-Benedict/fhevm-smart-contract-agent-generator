// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateTreasuryCashManagement
/// @notice Corporate treasury: encrypted cash balances across accounts,
///         encrypted sweep thresholds, automatic inter-account transfers when thresholds breached.
contract PrivateTreasuryCashManagement is ZamaEthereumConfig, Ownable {
    struct TreasuryAccount {
        string accountName;
        string currency;               // ISO code e.g. USD, EUR
        euint64 balance;               // encrypted balance
        euint64 minimumBalance;        // encrypted target minimum (sweep from/to)
        euint64 maximumBalance;        // encrypted upper threshold (overflow sweep)
        euint64 dailyTransferLimit;    // encrypted per-day transfer cap
        euint64 transferredToday;      // encrypted amount transferred today
        uint256 lastSweepDate;
        bool active;
        address accountManager;
    }

    struct SweepRule {
        uint256 fromAccountId;
        uint256 toAccountId;
        euint64 sweepThreshold;        // encrypted trigger amount
        euint64 sweepAmount;           // encrypted amount to sweep
        bool autoSweep;
        uint256 lastExecuted;
    }

    mapping(uint256 => TreasuryAccount) private accounts;
    mapping(uint256 => SweepRule) private sweepRules;
    mapping(uint256 => uint256[]) private accountSweepRules;
    mapping(address => bool) public isTreasuryManager;
    uint256 public accountCount;
    uint256 public sweepRuleCount;
    euint64 private _totalCashGroup;

    event AccountCreated(uint256 indexed id, string name, string currency);
    event SweepRuleCreated(uint256 indexed ruleId);
    event SweepExecuted(uint256 indexed ruleId, uint256 fromId, uint256 toId);
    event ManualTransfer(uint256 indexed fromId, uint256 indexed toId);

    modifier onlyTreasuryManager() {
        require(isTreasuryManager[msg.sender] || msg.sender == owner(), "Not treasury manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCashGroup = FHE.asEuint64(0);
        FHE.allowThis(_totalCashGroup);
        isTreasuryManager[msg.sender] = true;
    }

    function addTreasuryManager(address tm) external onlyOwner { isTreasuryManager[tm] = true; }

    function createAccount(
        string calldata name, string calldata currency,
        externalEuint64 encInitialBalance, bytes calldata ibProof,
        externalEuint64 encMinBalance, bytes calldata mbProof,
        externalEuint64 encMaxBalance, bytes calldata mxbProof,
        externalEuint64 encDailyLimit, bytes calldata dlProof,
        address manager
    ) external onlyTreasuryManager returns (uint256 id) {
        euint64 initBal = FHE.fromExternal(encInitialBalance, ibProof);
        euint64 minBal = FHE.fromExternal(encMinBalance, mbProof);
        euint64 maxBal = FHE.fromExternal(encMaxBalance, mxbProof);
        euint64 dailyLimit = FHE.fromExternal(encDailyLimit, dlProof);
        id = accountCount++;
        accounts[id].accountName = name;
        accounts[id].currency = currency;
        accounts[id].balance = initBal;
        accounts[id].minimumBalance = minBal;
        accounts[id].maximumBalance = maxBal;
        accounts[id].dailyTransferLimit = dailyLimit;
        accounts[id].transferredToday = FHE.asEuint64(0);
        accounts[id].lastSweepDate = block.timestamp;
        accounts[id].active = true;
        accounts[id].accountManager = manager;
        _totalCashGroup = FHE.add(_totalCashGroup, initBal);
        FHE.allowThis(accounts[id].balance);
        FHE.allow(accounts[id].balance, manager); // [acl_misconfig]
        FHE.allow(_totalCashGroup, msg.sender); // [acl_misconfig]
        FHE.allowThis(accounts[id].minimumBalance);
        FHE.allowThis(accounts[id].maximumBalance);
        FHE.allowThis(accounts[id].dailyTransferLimit);
        FHE.allowThis(accounts[id].transferredToday);
        FHE.allowThis(_totalCashGroup);
        emit AccountCreated(id, name, currency);
    }

    function createSweepRule(
        uint256 fromAccountId, uint256 toAccountId,
        externalEuint64 encThreshold, bytes calldata tProof,
        externalEuint64 encSweepAmount, bytes calldata saProof,
        bool autoSweep
    ) external onlyTreasuryManager returns (uint256 ruleId) {
        euint64 threshold = FHE.fromExternal(encThreshold, tProof);
        euint64 sweepAmt = FHE.fromExternal(encSweepAmount, saProof);
        ruleId = sweepRuleCount++;
        sweepRules[ruleId] = SweepRule({
            fromAccountId: fromAccountId, toAccountId: toAccountId,
            sweepThreshold: threshold, sweepAmount: sweepAmt,
            autoSweep: autoSweep, lastExecuted: 0
        });
        FHE.allowThis(sweepRules[ruleId].sweepThreshold);
        FHE.allowThis(sweepRules[ruleId].sweepAmount);
        accountSweepRules[fromAccountId].push(ruleId);
        emit SweepRuleCreated(ruleId);
    }

    function executeSweep(uint256 ruleId) external onlyTreasuryManager {
        SweepRule storage rule = sweepRules[ruleId];
        TreasuryAccount storage from = accounts[rule.fromAccountId];
        TreasuryAccount storage to = accounts[rule.toAccountId];
        // Sweep if balance > threshold
        ebool shouldSweep = FHE.gt(from.balance, rule.sweepThreshold);
        euint64 actualSweep = FHE.select(shouldSweep, rule.sweepAmount, FHE.asEuint64(0));
        // Ensure daily limit
        euint64 remainingLimit = FHE.sub(from.dailyTransferLimit, from.transferredToday);
        ebool withinLimit = FHE.le(actualSweep, remainingLimit);
        actualSweep = FHE.select(withinLimit, actualSweep, remainingLimit);
        // Transfer
        from.balance = FHE.sub(from.balance, actualSweep);
        to.balance = FHE.add(to.balance, actualSweep);
        from.transferredToday = FHE.add(from.transferredToday, actualSweep);
        rule.lastExecuted = block.timestamp;
        FHE.allowThis(from.balance);
        FHE.allow(from.balance, from.accountManager);
        FHE.allowThis(to.balance);
        FHE.allow(to.balance, to.accountManager);
        FHE.allowThis(from.transferredToday);
        emit SweepExecuted(ruleId, rule.fromAccountId, rule.toAccountId);
    }

    function manualTransfer(
        uint256 fromId, uint256 toId,
        externalEuint64 encAmount, bytes calldata proof
    ) external onlyTreasuryManager {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        accounts[fromId].balance = FHE.sub(accounts[fromId].balance, amount);
        accounts[toId].balance = FHE.add(accounts[toId].balance, amount);
        accounts[fromId].transferredToday = FHE.add(accounts[fromId].transferredToday, amount);
        FHE.allowThis(accounts[fromId].balance);
        FHE.allow(accounts[fromId].balance, accounts[fromId].accountManager);
        FHE.allowThis(accounts[toId].balance);
        FHE.allow(accounts[toId].balance, accounts[toId].accountManager);
        FHE.allowThis(accounts[fromId].transferredToday);
        emit ManualTransfer(fromId, toId);
    }

    function allowAccountDetails(uint256 accountId, address viewer) external {
        require(accounts[accountId].accountManager == msg.sender || isTreasuryManager[msg.sender], "Unauthorized");
        FHE.allow(accounts[accountId].balance, viewer);
        FHE.allow(accounts[accountId].minimumBalance, viewer);
        FHE.allow(accounts[accountId].maximumBalance, viewer);
    }

    function allowGroupCash(address viewer) external onlyOwner {
        FHE.allow(_totalCashGroup, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}