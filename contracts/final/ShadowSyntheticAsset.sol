// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ShadowSyntheticAsset is ZamaEthereumConfig, ERC20, Ownable {
    IERC20 public immutable collateralToken;

    struct Vault {
        euint64 encryptedCollateral;
        euint64 encryptedMintedSynth;
        bool isActive;
    }

    mapping(address => Vault) private vaults;
    euint32 private encryptedOraclePrice; // Price of collateral scaled by 100

    event VaultOpened(address indexed user);
    event SynthMinted(address indexed user);

    constructor(address _collateralToken) ERC20("Shadow USD", "sUSD") Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        encryptedOraclePrice = FHE.asEuint32(0);
        FHE.allowThis(encryptedOraclePrice);
    }

    function updateOraclePrice(externalEuint32 extPrice, bytes calldata proof) external onlyOwner {
        encryptedOraclePrice = FHE.fromExternal(extPrice, proof);
        FHE.allowThis(encryptedOraclePrice);
    }

    function depositAndMint(
        uint64 plaintextCollateralAmount,
        externalEuint64 extMintRequest,
        bytes calldata proofMint
    ) external {
        require(plaintextCollateralAmount > 0, "Zero collateral");
        require(collateralToken.transferFrom(msg.sender, address(this), plaintextCollateralAmount), "Transfer failed");

        euint64 mintRequest = FHE.fromExternal(extMintRequest, proofMint);
        FHE.allowThis(mintRequest);

        if (!vaults[msg.sender].isActive) {
            vaults[msg.sender] = Vault({
                encryptedCollateral: FHE.asEuint64(0),
                encryptedMintedSynth: FHE.asEuint64(0),
                isActive: true
            });
            FHE.allowThis(vaults[msg.sender].encryptedCollateral);
            FHE.allowThis(vaults[msg.sender].encryptedMintedSynth);
        }

        euint64 encColDeposit = FHE.asEuint64(uint64(plaintextCollateralAmount));
        vaults[msg.sender].encryptedCollateral = FHE.add(vaults[msg.sender].encryptedCollateral, encColDeposit);
        FHE.allowThis(vaults[msg.sender].encryptedCollateral);

        // Required Collateral Value = MintRequest * 150%
        euint64 requiredColValue = FHE.div(FHE.mul(mintRequest, 150), 100);
        
        // Actual Collateral Value = Total Collateral * Oracle Price
        euint64 encPrice64 = FHE.asEuint64(encryptedOraclePrice);
        euint64 actualColValue = FHE.mul(vaults[msg.sender].encryptedCollateral, encPrice64); // [arithmetic_overflow_underflow]
        euint64 encPrice64Scaled = FHE.mul(encPrice64, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        
        FHE.allowThis(requiredColValue);
        FHE.allowThis(actualColValue);

        // Check if collateralization ratio is healthy
        ebool isHealthy = FHE.ge(actualColValue, requiredColValue);

        vaults[msg.sender].encryptedMintedSynth = FHE.add(vaults[msg.sender].encryptedMintedSynth, mintRequest);
        FHE.allowThis(vaults[msg.sender].encryptedMintedSynth);

        uint64 decryptedMintAmount = 0;
        _mint(msg.sender, decryptedMintAmount);

        emit SynthMinted(msg.sender);
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