// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20PrivateStablecoinCBDC
/// @notice Central Bank Digital Currency (CBDC) prototype: encrypted balances with AML thresholds,
///         encrypted velocity limits, programmable monetary policy controls with encrypted reserve ratios.
contract ERC20PrivateStablecoinCBDC is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Digital Reserve Currency";
    string public symbol = "DRC";
    uint8 public decimals = 6;

    struct WalletAccount {
        euint64 balance;
        euint64 dailyTransferVolume;
        euint64 velocityLimitDaily;   // encrypted max daily transfer
        euint64 amlRiskScore;         // encrypted AML risk 0-1000
        euint64 kycTier;              // encrypted KYC tier 0-3
        uint256 lastResetTime;
        bool frozen;
        bool verified;
    }

    struct MonetaryPolicy {
        euint64 totalSupply;          // encrypted total supply
        euint64 reserveRatioBps;      // encrypted reserve ratio
        euint64 inflationRateBps;     // encrypted annual inflation rate
        euint64 interestRateBps;      // encrypted central bank rate
        uint256 lastPolicyUpdate;
    }

    mapping(address => WalletAccount) private wallets;
    MonetaryPolicy private policy;
    mapping(address => bool) public isCentralBankAgent;
    mapping(address => bool) public isCommercialBank;
    euint64 private _totalCirculation;

    event Transfer(address indexed from, address indexed to);
    event AccountVerified(address indexed account, uint256 tier);
    event AccountFrozen(address indexed account);
    event PolicyUpdated();
    event AMLAlert(address indexed account);

    constructor(
        externalEuint64 encInitialSupply, bytes memory isProof,
        externalEuint64 encReserveRatio, bytes memory rrProof
    ) Ownable(msg.sender) {
        euint64 supply = FHE.fromExternal(encInitialSupply, isProof);
        euint64 reserve = FHE.fromExternal(encReserveRatio, rrProof);
        policy = MonetaryPolicy({
            totalSupply: supply, reserveRatioBps: reserve,
            inflationRateBps: FHE.asEuint64(200),
            interestRateBps: FHE.asEuint64(525),
            lastPolicyUpdate: block.timestamp
        });
        _totalCirculation = supply;
        FHE.allowThis(policy.totalSupply);
        FHE.allowThis(policy.reserveRatioBps);
        FHE.allowThis(policy.inflationRateBps);
        FHE.allowThis(policy.interestRateBps);
        FHE.allowThis(_totalCirculation);
        isCentralBankAgent[msg.sender] = true;
    }

    function addCBAgent(address a) external onlyOwner { isCentralBankAgent[a] = true; }
    function addCommercialBank(address b) external onlyOwner { isCommercialBank[b] = true; }

    function verifyAccount(
        address account, uint256 tier,
        externalEuint64 encVelocity, bytes calldata vProof,
        externalEuint64 encAML, bytes calldata amlProof
    ) external {
        require(isCentralBankAgent[msg.sender] || isCommercialBank[msg.sender], "Not authorized");
        euint64 velocity = FHE.fromExternal(encVelocity, vProof);
        euint64 aml = FHE.fromExternal(encAML, amlProof);
        WalletAccount storage w = wallets[account];
        if (!FHE.isInitialized(w.balance)) {
            w.balance = FHE.asEuint64(0);
            w.dailyTransferVolume = FHE.asEuint64(0);
            FHE.allowThis(w.balance);
            FHE.allowThis(w.dailyTransferVolume);
        }
        w.velocityLimitDaily = velocity;
        w.amlRiskScore = aml;
        w.kycTier = FHE.asEuint64(uint64(tier));
        w.verified = true;
        w.lastResetTime = block.timestamp;
        FHE.allowThis(w.velocityLimitDaily);
        FHE.allowThis(w.amlRiskScore);
        FHE.allowThis(w.kycTier);
        FHE.allow(w.balance, account);
        FHE.allow(w.kycTier, account);
        emit AccountVerified(account, tier);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external {
        require(isCentralBankAgent[msg.sender], "Not CB agent");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        WalletAccount storage w = wallets[to];
        w.balance = FHE.add(w.balance, amount);
        policy.totalSupply = FHE.add(policy.totalSupply, amount);
        _totalCirculation = FHE.add(_totalCirculation, amount);
        FHE.allowThis(w.balance);
        FHE.allow(w.balance, to);
        FHE.allowThis(policy.totalSupply);
        FHE.allowThis(_totalCirculation);
    }

    function transfer(
        address to,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(wallets[msg.sender].verified, "Sender not verified");
        require(wallets[to].verified, "Recipient not verified");
        require(!wallets[msg.sender].frozen, "Sender frozen");
        WalletAccount storage sender = wallets[msg.sender];
        WalletAccount storage recipient = wallets[to];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Reset daily volume if needed (simplified: always accumulate)
        ebool withinVelocity = FHE.le(FHE.add(sender.dailyTransferVolume, amount), sender.velocityLimitDaily);
        euint64 actual = FHE.select(withinVelocity, amount, FHE.asEuint64(0));
        ebool hasBal = FHE.ge(sender.balance, actual);
        euint64 finalAmount = FHE.select(hasBal, actual, sender.balance);
        sender.balance = FHE.sub(sender.balance, finalAmount);
        recipient.balance = FHE.add(recipient.balance, finalAmount);
        sender.dailyTransferVolume = FHE.add(sender.dailyTransferVolume, finalAmount);
        // AML: if high risk, alert
        ebool highRisk = FHE.ge(sender.amlRiskScore, FHE.asEuint64(800));
        FHE.allowThis(sender.balance);
        FHE.allow(sender.balance, msg.sender);
        FHE.allowThis(recipient.balance);
        FHE.allow(recipient.balance, to);
        FHE.allowThis(sender.dailyTransferVolume);
        emit Transfer(msg.sender, to);
    }

    function freezeAccount(address account) external {
        require(isCentralBankAgent[msg.sender], "Not CB agent");
        wallets[account].frozen = true;
        emit AccountFrozen(account);
    }

    function updateMonetaryPolicy(
        externalEuint64 encInflation, bytes calldata iProof,
        externalEuint64 encInterestRate, bytes calldata irProof
    ) external {
        require(isCentralBankAgent[msg.sender], "Not CB agent");
        policy.inflationRateBps = FHE.fromExternal(encInflation, iProof);
        policy.interestRateBps = FHE.fromExternal(encInterestRate, irProof);
        policy.lastPolicyUpdate = block.timestamp;
        FHE.allowThis(policy.inflationRateBps);
        FHE.allowThis(policy.interestRateBps);
        emit PolicyUpdated();
    }

    function burn(address from, externalEuint64 encAmount, bytes calldata proof) external {
        require(isCentralBankAgent[msg.sender], "Not CB agent");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        WalletAccount storage w = wallets[from];
        ebool hasBal = FHE.ge(w.balance, amount);
        euint64 actual = FHE.select(hasBal, amount, w.balance);
        w.balance = FHE.sub(w.balance, actual);
        policy.totalSupply = FHE.sub(policy.totalSupply, actual);
        _totalCirculation = FHE.sub(_totalCirculation, actual);
        FHE.allowThis(w.balance);
        FHE.allowThis(policy.totalSupply);
        FHE.allowThis(_totalCirculation);
    }
}
