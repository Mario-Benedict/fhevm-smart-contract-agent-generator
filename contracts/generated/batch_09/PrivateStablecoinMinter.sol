// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateStablecoinMinter - Confidential over-collateralized stablecoin minting engine
contract PrivateStablecoinMinter is ZamaEthereumConfig, Ownable {
    string public constant name = "PrivateUSD";
    string public constant symbol = "PUSD";

    struct Vault {
        euint64 collateralETH;
        euint64 mintedPUSD;
        bool open;
    }

    mapping(address => Vault) public vaults;
    mapping(address => euint64) private pusdBalances;
    euint64 private _totalPUSD;
    uint64 public ethPriceUSD; // set by oracle/owner, plaintext for ratio calc
    uint16 public minCollateralRatioBps = 17000; // 170%

    event VaultOpened(address indexed owner);
    event CollateralLocked(address indexed owner);
    event StablecoinMinted(address indexed owner);
    event StablecoinBurned(address indexed owner);

    constructor(uint64 _ethPriceUSD) Ownable(msg.sender) {
        ethPriceUSD = _ethPriceUSD;
        _totalPUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPUSD);
    }

    function openVault() external {
        require(!vaults[msg.sender].open, "Vault exists");
        vaults[msg.sender].collateralETH = FHE.asEuint64(0);
        vaults[msg.sender].mintedPUSD = FHE.asEuint64(0);
        vaults[msg.sender].open = true;
        FHE.allowThis(vaults[msg.sender].collateralETH);
        FHE.allowThis(vaults[msg.sender].mintedPUSD);
        FHE.allow(vaults[msg.sender].collateralETH, msg.sender);
        FHE.allow(vaults[msg.sender].mintedPUSD, msg.sender);
        emit VaultOpened(msg.sender);
    }

    function lockCollateral(externalEuint64 encWei, bytes calldata inputProof) external {
        require(vaults[msg.sender].open, "No vault");
        euint64 amount = FHE.fromExternal(encWei, inputProof);
        vaults[msg.sender].collateralETH = FHE.add(vaults[msg.sender].collateralETH, amount);
        FHE.allowThis(vaults[msg.sender].collateralETH);
        FHE.allow(vaults[msg.sender].collateralETH, msg.sender);
        emit CollateralLocked(msg.sender);
    }

    function mintPUSD(externalEuint64 encMintAmount, bytes calldata inputProof) external {
        require(vaults[msg.sender].open, "No vault");
        euint64 mintAmount = FHE.fromExternal(encMintAmount, inputProof);
        euint64 collateralValue = FHE.mul(vaults[msg.sender].collateralETH, ethPriceUSD);
        euint64 maxMint = FHE.div(FHE.mul(collateralValue, 10000), uint64(minCollateralRatioBps));
        euint64 newTotal = FHE.add(vaults[msg.sender].mintedPUSD, mintAmount);
        ebool safe = FHE.le(newTotal, maxMint);
        euint64 safeMint = FHE.select(safe, mintAmount, FHE.asEuint64(0));
        vaults[msg.sender].mintedPUSD = FHE.add(vaults[msg.sender].mintedPUSD, safeMint);
        pusdBalances[msg.sender] = FHE.add(pusdBalances[msg.sender], safeMint);
        _totalPUSD = FHE.add(_totalPUSD, safeMint);
        FHE.allowThis(vaults[msg.sender].mintedPUSD);
        FHE.allowThis(pusdBalances[msg.sender]);
        FHE.allowThis(_totalPUSD);
        FHE.allow(pusdBalances[msg.sender], msg.sender);
        emit StablecoinMinted(msg.sender);
    }

    function updateEthPrice(uint64 newPrice) external onlyOwner {
        ethPriceUSD = newPrice;
    }

    function getPUSDBalance(address account) external view returns (euint64) {
        return pusdBalances[account];
    }
}
