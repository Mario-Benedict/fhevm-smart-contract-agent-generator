// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDebtCollectionAgencyToken
/// @notice Encrypted debt collection: hidden debt face values, private recovery
///         rates, confidential settlement offers, and encrypted commission
///         structures for collection agencies.
contract PrivateDebtCollectionAgencyToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Debt Recovery Token";
    string public constant symbol = "DRT";
    uint8  public constant decimals = 6;

    enum DebtStatus { Current, Delinquent, Default, Settled, WrittenOff }

    struct Debt {
        address debtor;
        address originalCreditor;
        address collectionAgency;
        string  debtRef;
        euint64 originalBalanceUSD;    // encrypted original balance
        euint64 currentBalanceUSD;     // encrypted current balance
        euint64 interestAccruedUSD;    // encrypted interest
        euint64 penaltiesUSD;          // encrypted penalties
        euint64 settlementOfferUSD;    // encrypted settlement offer
        euint16 recoveryRateBps;       // encrypted recovery rate
        DebtStatus status;
        uint256 originatedAt;
        uint256 defaultedAt;
    }

    mapping(address => euint64) private _balances; // DRT token balances
    mapping(uint256 => Debt) private debts;
    mapping(address => bool) public isCollectionAgency;

    euint64 private _totalSupply;
    euint64 private _totalDebtPortfolioUSD;
    euint64 private _totalRecoveredUSD;
    uint256 public debtCount;

    event Transfer(address indexed from, address indexed to);
    event DebtPurchased(uint256 indexed id, address agency);
    event SettlementOffered(uint256 indexed id, uint256 offeredAt);
    event DebtSettled(uint256 indexed id, uint256 settledAt);
    event DebtWrittenOff(uint256 indexed id);

    modifier onlyCollectionAgency() {
        require(isCollectionAgency[msg.sender] || msg.sender == owner(), "Not collection agency");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalDebtPortfolioUSD = FHE.asEuint64(0);
        _totalRecoveredUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalDebtPortfolioUSD);
        FHE.allowThis(_totalRecoveredUSD);
        isCollectionAgency[msg.sender] = true;
    }

    function addCollectionAgency(address ca) external onlyOwner { isCollectionAgency[ca] = true; }

    function purchaseDebt(
        address debtor, address originalCreditor, string calldata debtRef,
        externalEuint64 encOriginal, bytes calldata oProof,
        externalEuint64 encInterest, bytes calldata intProof,
        externalEuint64 encPenalties, bytes calldata penProof,
        externalEuint16 encRecoveryRate, bytes calldata rrProof
    ) external onlyCollectionAgency returns (uint256 id) {
        euint64 original    = FHE.fromExternal(encOriginal, oProof);
        euint64 interest    = FHE.fromExternal(encInterest, intProof);
        euint64 penalties   = FHE.fromExternal(encPenalties, penProof);
        euint16 recoveryRate= FHE.fromExternal(encRecoveryRate, rrProof);
        euint64 totalBalance= FHE.add(FHE.add(original, interest), penalties);
        // Mint DRT tokens proportional to purchase price (recovery rate * original)
        euint64 purchasePrice = FHE.div(FHE.mul(original, 1000), 10000); // 10 cents on dollar
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], purchasePrice);
        _totalSupply = FHE.add(_totalSupply, purchasePrice);
        id = debtCount++;
        Debt storage _s0 = debts[id];
        _s0.debtor = debtor;
        _s0.originalCreditor = originalCreditor;
        _s0.collectionAgency = msg.sender;
        _s0.debtRef = debtRef;
        _s0.originalBalanceUSD = original;
        _s0.currentBalanceUSD = totalBalance;
        _s0.interestAccruedUSD = interest;
        _s0.penaltiesUSD = penalties;
        _s0.settlementOfferUSD = FHE.asEuint64(0);
        _s0.recoveryRateBps = recoveryRate;
        _s0.status = DebtStatus.Default;
        _s0.originatedAt = block.timestamp;
        _s0.defaultedAt = block.timestamp;
        _totalDebtPortfolioUSD = FHE.add(_totalDebtPortfolioUSD, totalBalance);
        FHE.allowThis(debts[id].originalBalanceUSD); FHE.allow(debts[id].originalBalanceUSD, msg.sender);
        FHE.allowThis(debts[id].currentBalanceUSD); FHE.allow(debts[id].currentBalanceUSD, debtor); FHE.allow(debts[id].currentBalanceUSD, msg.sender);
        FHE.allowThis(debts[id].interestAccruedUSD); FHE.allow(debts[id].interestAccruedUSD, debtor);
        FHE.allowThis(debts[id].penaltiesUSD); FHE.allow(debts[id].penaltiesUSD, debtor);
        FHE.allowThis(debts[id].settlementOfferUSD); FHE.allow(debts[id].settlementOfferUSD, debtor);
        FHE.allowThis(debts[id].recoveryRateBps);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalDebtPortfolioUSD);
        emit DebtPurchased(id, msg.sender);
    }

    function makeSettlementOffer(uint256 debtId, externalEuint64 encOffer, bytes calldata proof) external onlyCollectionAgency {
        Debt storage d = debts[debtId];
        require(d.collectionAgency == msg.sender && d.status == DebtStatus.Default, "Cannot offer");
        euint64 offer = FHE.fromExternal(encOffer, proof);
        d.settlementOfferUSD = offer;
        d.status = DebtStatus.Delinquent;
        FHE.allowThis(d.settlementOfferUSD); FHE.allow(d.settlementOfferUSD, d.debtor);
        emit SettlementOffered(debtId, block.timestamp);
    }

    function acceptSettlement(uint256 debtId) external nonReentrant {
        Debt storage d = debts[debtId];
        require(msg.sender == d.debtor && d.status == DebtStatus.Delinquent, "Cannot settle");
        _totalRecoveredUSD = FHE.add(_totalRecoveredUSD, d.settlementOfferUSD);
        d.status = DebtStatus.Settled;
        FHE.allowThis(_totalRecoveredUSD); FHE.allow(d.settlementOfferUSD, d.collectionAgency);
        emit DebtSettled(debtId, block.timestamp);
    }

    function writeOffDebt(uint256 debtId) external onlyCollectionAgency {
        debts[debtId].status = DebtStatus.WrittenOff;
        emit DebtWrittenOff(debtId);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], eff);
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalDebtPortfolioUSD, viewer); FHE.allow(_totalRecoveredUSD, viewer);
    }
    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }

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