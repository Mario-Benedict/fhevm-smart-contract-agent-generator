// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ConfidentialERC20StableCoin
/// @notice Encrypted algorithmic stablecoin: mint/burn based on encrypted collateral ratio.
///         Encrypted peg maintained by oracle-updated encrypted price feed.
contract ConfidentialERC20StableCoin is ZamaEthereumConfig, Ownable {
    string public constant name = "Confidential USD";
    string public constant symbol = "cUSD";

    euint64 private _totalSupply;
    euint64 private _collateralRatioBps;  // encrypted target ratio e.g. 15000 = 150%
    euint64 private _pegPrice;            // encrypted peg price (should be 1e6 = $1.00)
    euint64 private _totalCollateral;
    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _collateralDeposited;
    mapping(address => bool) public isMinter;
    address public priceOracle;

    event Minted(address indexed to);
    event Burned(address indexed from);
    event CollateralDeposited(address indexed user);
    event PegPriceUpdated();

    constructor(externalEuint64 encRatio, bytes memory rProof, address oracle) Ownable(msg.sender) {
        _collateralRatioBps = FHE.fromExternal(encRatio, rProof);
        _pegPrice = FHE.asEuint64(1_000_000); // $1.00 * 1e6
        _totalSupply = FHE.asEuint64(0);
        _totalCollateral = FHE.asEuint64(0);
        priceOracle = oracle;
        isMinter[msg.sender] = true;
        FHE.allowThis(_collateralRatioBps);
        FHE.allowThis(_pegPrice);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalCollateral);
    }

    function addMinter(address m) external onlyOwner { isMinter[m] = true; }

    function depositCollateral(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _collateralDeposited[msg.sender] = FHE.add(_collateralDeposited[msg.sender], amount);
        _totalCollateral = FHE.add(_totalCollateral, amount);
        FHE.allowThis(_collateralDeposited[msg.sender]);
        FHE.allow(_collateralDeposited[msg.sender], msg.sender);
        FHE.allowThis(_totalCollateral);
        emit CollateralDeposited(msg.sender);
    }

    function mint(externalEuint64 encMintAmount, bytes calldata proof) external {
        require(isMinter[msg.sender], "Not minter");
        euint64 mintAmt = FHE.fromExternal(encMintAmount, proof);
        // Required collateral = mintAmt * ratio / 10000
        euint64 requiredCollateral = FHE.div(FHE.mul(mintAmt, _collateralRatioBps), 10000);
        ebool hasCollateral = FHE.ge(_collateralDeposited[msg.sender], requiredCollateral);
        euint64 actualMint = FHE.select(hasCollateral, mintAmt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.add(_balances[msg.sender], actualMint);
        _totalSupply = FHE.add(_totalSupply, actualMint);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        emit Minted(msg.sender);
    }

    function burn(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasBal = FHE.le(amount, _balances[msg.sender]);
        euint64 actualBurn = FHE.select(hasBal, amount, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualBurn);
        _totalSupply = FHE.sub(_totalSupply, actualBurn);
        // Release proportional collateral
        euint64 collateralRelease = FHE.div(FHE.mul(actualBurn, _collateralRatioBps), 10000);
        ebool hasColl = FHE.le(collateralRelease, _collateralDeposited[msg.sender]);
        euint64 released = FHE.select(hasColl, collateralRelease, _collateralDeposited[msg.sender]);
        _collateralDeposited[msg.sender] = FHE.sub(_collateralDeposited[msg.sender], released);
        _totalCollateral = FHE.sub(_totalCollateral, released);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_collateralDeposited[msg.sender]);
        FHE.allowThis(_totalCollateral);
        FHE.allow(released, msg.sender);
        emit Burned(msg.sender);
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

    function updatePegPrice(externalEuint64 encPrice, bytes calldata proof) external {
        require(msg.sender == priceOracle || msg.sender == owner(), "Not oracle");
        _pegPrice = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(_pegPrice);
        emit PegPriceUpdated();
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }

    function allowSupplyStats(address viewer) external onlyOwner {
        FHE.allow(_totalSupply, viewer);
        FHE.allow(_totalCollateral, viewer);
        FHE.allow(_pegPrice, viewer);
    }
}
