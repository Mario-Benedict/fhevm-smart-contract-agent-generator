// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedRetailLoyaltyCashback
/// @notice Retail loyalty program where purchase amounts and cashback tiers are encrypted.
///         Merchants submit encrypted purchase totals; users accrue hidden cashback points
///         redeemable against future purchases without revealing spending patterns.
contract EncryptedRetailLoyaltyCashback is ZamaEthereumConfig, AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant MERCHANT_ROLE = keccak256("MERCHANT_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    string public constant programName = "RetailPrivacyRewards";
    string public constant symbol = "RPR";

    // Tier thresholds (plaintext for simplicity of comparison)
    uint64 public constant SILVER_THRESHOLD = 1000;
    uint64 public constant GOLD_THRESHOLD = 5000;
    uint64 public constant PLATINUM_THRESHOLD = 20000;

    // Cashback rates stored as basis points (plaintext)
    uint64 public constant SILVER_BPS = 100;   // 1%
    uint64 public constant GOLD_BPS = 250;     // 2.5%
    uint64 public constant PLATINUM_BPS = 500; // 5%

    struct MemberAccount {
        euint64 lifetimePurchase;  // encrypted cumulative spend
        euint64 cashbackBalance;   // encrypted redeemable cashback
        uint256 lastActivityBlock;
        bool enrolled;
    }

    mapping(address => MemberAccount) private members;
    mapping(address => bool) public merchantActive;

    euint64 private _totalCashbackLiability;

    event MemberEnrolled(address indexed member);
    event PurchaseRecorded(address indexed member, address indexed merchant);
    event CashbackRedeemed(address indexed member);
    event MerchantRegistered(address indexed merchant);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _totalCashbackLiability = FHE.asEuint64(0);
        FHE.allowThis(_totalCashbackLiability);
    }

    function registerMerchant(address merchant) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MERCHANT_ROLE, merchant);
        merchantActive[merchant] = true;
        emit MerchantRegistered(merchant);
    }

    function enroll() external {
        require(!members[msg.sender].enrolled, "Already enrolled");
        members[msg.sender].enrolled = true;
        members[msg.sender].lifetimePurchase = FHE.asEuint64(0);
        members[msg.sender].cashbackBalance = FHE.asEuint64(0);
        FHE.allowThis(members[msg.sender].lifetimePurchase);
        FHE.allowThis(members[msg.sender].cashbackBalance);
        FHE.allow(members[msg.sender].cashbackBalance, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCashbackLiability, msg.sender); // [acl_misconfig]
        emit MemberEnrolled(msg.sender);
    }

    /// @notice Merchant records an encrypted purchase for a member
    function recordPurchase(
        address member,
        externalEuint64 encAmount,
        bytes calldata proof,
        uint8 tier // 0=silver,1=gold,2=platinum (computed offchain by merchant)
    ) external onlyRole(MERCHANT_ROLE) whenNotPaused nonReentrant {
        require(members[member].enrolled, "Member not enrolled");
        require(tier <= 2, "Invalid tier");

        euint64 amount = FHE.fromExternal(encAmount, proof);
        members[member].lifetimePurchase = FHE.add(members[member].lifetimePurchase, amount);
        FHE.allowThis(members[member].lifetimePurchase);

        // Compute cashback based on declared tier
        uint64 bps = tier == 0 ? SILVER_BPS : (tier == 1 ? GOLD_BPS : PLATINUM_BPS);
        // cashback = amount * bps / 10000  — use FHE.mul then FHE.div
        euint64 cashback = FHE.div(FHE.mul(amount, bps), 10000);
        members[member].cashbackBalance = FHE.add(members[member].cashbackBalance, cashback);
        FHE.allowThis(members[member].cashbackBalance);
        FHE.allow(members[member].cashbackBalance, member);

        _totalCashbackLiability = FHE.add(_totalCashbackLiability, cashback);
        FHE.allowThis(_totalCashbackLiability);

        members[member].lastActivityBlock = block.number;
        emit PurchaseRecorded(member, msg.sender);
    }

    /// @notice Member redeems cashback — sets balance to zero encrypted
    function redeemCashback() external nonReentrant whenNotPaused {
        require(members[msg.sender].enrolled, "Not enrolled");
        euint64 redeemable = members[msg.sender].cashbackBalance;
        members[msg.sender].cashbackBalance = FHE.asEuint64(0);
        FHE.allowThis(members[msg.sender].cashbackBalance);
        FHE.allow(members[msg.sender].cashbackBalance, msg.sender);

        _totalCashbackLiability = FHE.sub(_totalCashbackLiability, redeemable);
        FHE.allowThis(_totalCashbackLiability);
        emit CashbackRedeemed(msg.sender);
    }

    function allowAuditorView(address auditor) external onlyRole(AUDITOR_ROLE) {
        FHE.allow(_totalCashbackLiability, auditor);
    }

    function allowMemberView(address viewer) external {
        require(members[msg.sender].enrolled, "Not enrolled");
        FHE.allow(members[msg.sender].cashbackBalance, viewer);
        FHE.allow(members[msg.sender].lifetimePurchase, viewer);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
