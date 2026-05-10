// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedVaultedGoldBacking
/// @notice Gold-backed token where vault holds encrypted physical gold inventory.
///         Users mint tokens backed by encrypted gold weight; redemption triggers vault release.
contract EncryptedVaultedGoldBacking is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Gold Backed Token";
    string public constant symbol = "GBT";
    uint8 public constant GRAMS_PER_TOKEN = 1; // 1 token = 1 gram gold

    euint64 private _vaultGoldGrams;       // encrypted grams of gold in vault
    euint64 private _totalTokenSupply;     // encrypted token supply
    euint64 private _goldPriceUSDPerGram;  // encrypted spot gold price
    euint64 private _storageFeeBpsAnnual;  // encrypted annual storage fee
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _redemptionRequests;
    mapping(address => bool) public isVaultCustodian;
    address public goldOracle;
    uint256 public lastFeeCollection;

    event GoldDeposited(uint256 gramsEncoded);
    event TokensMinted(address indexed to);
    event RedemptionRequested(address indexed from);
    event GoldRedeemed(address indexed to);
    event GoldPriceUpdated();
    event StorageFeeCollected();

    modifier onlyCustodian() {
        require(isVaultCustodian[msg.sender] || msg.sender == owner(), "Not custodian");
        _;
    }

    constructor(
        address oracle,
        externalEuint64 encGoldPrice, bytes memory gProof,
        externalEuint64 encStorageFee, bytes memory sfProof
    ) Ownable(msg.sender) {
        goldOracle = oracle;
        _goldPriceUSDPerGram = FHE.fromExternal(encGoldPrice, gProof);
        _storageFeeBpsAnnual = FHE.fromExternal(encStorageFee, sfProof);
        _vaultGoldGrams = FHE.asEuint64(0);
        _totalTokenSupply = FHE.asEuint64(0);
        FHE.allowThis(_goldPriceUSDPerGram);
        FHE.allowThis(_storageFeeBpsAnnual);
        FHE.allowThis(_vaultGoldGrams);
        FHE.allowThis(_totalTokenSupply);
        isVaultCustodian[msg.sender] = true;
        lastFeeCollection = block.timestamp;
    }

    function addCustodian(address c) external onlyOwner { isVaultCustodian[c] = true; }

    function depositGold(externalEuint64 encGrams, bytes calldata proof) external onlyCustodian {
        euint64 grams = FHE.fromExternal(encGrams, proof);
        _vaultGoldGrams = FHE.add(_vaultGoldGrams, grams);
        FHE.allowThis(_vaultGoldGrams);
        emit GoldDeposited(0); // grams amount not revealed in event
    }

    function mintTokens(address to, externalEuint64 encGrams, bytes calldata proof) external onlyCustodian nonReentrant {
        euint64 grams = FHE.fromExternal(encGrams, proof);
        // Ensure vault has sufficient gold
        ebool hasGold = FHE.ge(_vaultGoldGrams, grams);
        euint64 tokensToMint = FHE.select(hasGold, grams, FHE.asEuint64(0)); // 1:1 gram:token
        _balances[to] = FHE.add(_balances[to], tokensToMint);
        _totalTokenSupply = FHE.add(_totalTokenSupply, tokensToMint);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to); // [acl_misconfig]
        FHE.allow(_vaultGoldGrams, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTokenSupply, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalTokenSupply);
        emit TokensMinted(to);
    }

    function requestRedemption(externalEuint64 encTokens, bytes calldata proof) external {
        euint64 tokens = FHE.fromExternal(encTokens, proof);
        ebool hasBalance = FHE.le(tokens, _balances[msg.sender]);
        euint64 actualTokens = FHE.select(hasBalance, tokens, _balances[msg.sender]);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualTokens);
        _redemptionRequests[msg.sender] = FHE.add(_redemptionRequests[msg.sender], actualTokens);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_redemptionRequests[msg.sender]);
        FHE.allow(_redemptionRequests[msg.sender], msg.sender);
        emit RedemptionRequested(msg.sender);
    }

    function fulfillRedemption(address to) external onlyCustodian {
        euint64 goldToRelease = _redemptionRequests[to];
        _vaultGoldGrams = FHE.sub(_vaultGoldGrams, goldToRelease);
        _totalTokenSupply = FHE.sub(_totalTokenSupply, goldToRelease);
        _redemptionRequests[to] = FHE.asEuint64(0);
        FHE.allowThis(_vaultGoldGrams);
        FHE.allowThis(_totalTokenSupply);
        FHE.allowThis(_redemptionRequests[to]);
        FHE.allow(goldToRelease, to); // prove amount released
        emit GoldRedeemed(to);
    }

    function updateGoldPrice(externalEuint64 encNewPrice, bytes calldata proof) external {
        require(msg.sender == goldOracle || msg.sender == owner(), "Not oracle");
        _goldPriceUSDPerGram = FHE.fromExternal(encNewPrice, proof);
        FHE.allowThis(_goldPriceUSDPerGram);
        emit GoldPriceUpdated();
    }

    function collectStorageFee() external onlyCustodian {
        uint256 yearsElapsed = (block.timestamp - lastFeeCollection) / 365 days;
        if (yearsElapsed == 0) return;
        euint64 fee = FHE.div(FHE.mul(_vaultGoldGrams, _storageFeeBpsAnnual), 10000);
        _vaultGoldGrams = FHE.sub(_vaultGoldGrams, fee);
        lastFeeCollection = block.timestamp;
        FHE.allowThis(_vaultGoldGrams);
        FHE.allow(fee, owner());
        emit StorageFeeCollected();
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.le(amount, _balances[msg.sender]);
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
    }

    function allowVaultStats(address viewer) external onlyCustodian {
        FHE.allow(_vaultGoldGrams, viewer);
        FHE.allow(_totalTokenSupply, viewer);
        FHE.allow(_goldPriceUSDPerGram, viewer);
    }
}
