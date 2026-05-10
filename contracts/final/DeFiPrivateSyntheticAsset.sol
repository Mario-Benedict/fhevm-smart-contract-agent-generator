// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiPrivateSyntheticAsset
/// @notice Synthetic asset minting protocol with encrypted collateral factors.
///         Users mint synthetic tokens by locking collateral at an encrypted ratio.
///         Price oracle feeds are encrypted to prevent oracle front-running.
contract DeFiPrivateSyntheticAsset is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public syntheticName;
    string public syntheticSymbol;

    struct SynthPosition {
        euint64 collateral;
        euint64 minted;            // synthetic tokens minted
        euint64 collateralRatioBps; // encrypted required ratio
        bool active;
        uint256 openedAt;
    }

    mapping(address => SynthPosition) private positions;
    euint64 private _totalCollateral;
    euint64 private _totalMinted;
    euint64 private _oraclePrice;    // encrypted oracle price
    euint64 private _minRatioBps;    // encrypted minimum collateral ratio (e.g. 15000 = 150%)
    euint64 private _synthFeesBps;

    event PositionOpened(address indexed user);
    event PositionClosed(address indexed user);
    event OraclePriceUpdated();
    event Liquidated(address indexed user);

    constructor(
        string memory name_, string memory symbol_,
        externalEuint64 encMinRatio, bytes memory rProof,
        externalEuint64 encFees, bytes memory fProof
    ) Ownable(msg.sender) {
        syntheticName = name_;
        syntheticSymbol = symbol_;
        _minRatioBps = FHE.fromExternal(encMinRatio, rProof);
        _synthFeesBps = FHE.fromExternal(encFees, fProof);
        _totalCollateral = FHE.asEuint64(0);
        _totalMinted = FHE.asEuint64(0);
        _oraclePrice = FHE.asEuint64(1);
        FHE.allowThis(_minRatioBps);
        FHE.allowThis(_synthFeesBps);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalMinted);
        FHE.allowThis(_oraclePrice);
    }

    function updateOraclePrice(externalEuint64 encPrice, bytes calldata proof) external onlyOwner {
        _oraclePrice = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(_oraclePrice);
        emit OraclePriceUpdated();
    }

    function openPosition(
        externalEuint64 encCollateral, bytes calldata cProof,
        externalEuint64 encMintAmount, bytes calldata mProof
    ) external nonReentrant {
        require(!positions[msg.sender].active, "Position exists");
        euint64 collateral = FHE.fromExternal(encCollateral, cProof);
        euint64 mintAmount = FHE.fromExternal(encMintAmount, mProof);
        // Collateral must be >= mintAmount * oraclePrice * minRatio / 10000
        ebool _safeMul29 = FHE.le(FHE.mul(mintAmount, _oraclePrice), FHE.asEuint64(type(uint32).max));
        euint64 collateralRequired = FHE.select(_safeMul29, FHE.div(
            FHE.mul(FHE.mul(mintAmount, _oraclePrice), _minRatioBps),
            10000
        ), FHE.asEuint64(type(uint32).max));
        ebool safeToMint = FHE.ge(collateral, collateralRequired);
        euint64 actualMint = FHE.select(safeToMint, mintAmount, FHE.asEuint64(0));
        euint64 fee = FHE.div(FHE.mul(actualMint, _synthFeesBps), 10000);
        ebool _safeSub129 = FHE.ge(actualMint, fee);
        euint64 netMint = FHE.select(_safeSub129, FHE.sub(actualMint, fee), FHE.asEuint64(0));
        positions[msg.sender] = SynthPosition({
            collateral: collateral,
            minted: netMint,
            collateralRatioBps: _minRatioBps,
            active: FHE.isInitialized(safeToMint),
            openedAt: block.timestamp
        });
        _totalCollateral = FHE.add(_totalCollateral, collateral);
        _totalMinted = FHE.add(_totalMinted, netMint);
        FHE.allowThis(positions[msg.sender].collateral);
        FHE.allow(positions[msg.sender].collateral, msg.sender);
        FHE.allowThis(positions[msg.sender].minted);
        FHE.allow(positions[msg.sender].minted, msg.sender);
        FHE.allowThis(positions[msg.sender].collateralRatioBps);
        FHE.allowThis(_totalCollateral);
        FHE.allowThis(_totalMinted);
        FHE.allow(netMint, msg.sender);
        emit PositionOpened(msg.sender);
    }

    function burnAndClose(externalEuint64 encBurnAmount, bytes calldata proof) external nonReentrant {
        SynthPosition storage p = positions[msg.sender];
        require(p.active, "No position");
        euint64 burnAmount = FHE.fromExternal(encBurnAmount, proof);
        ebool burnAll = FHE.ge(burnAmount, p.minted);
        euint64 actualBurn = FHE.select(burnAll, p.minted, burnAmount);
        euint64 collateralReturn = FHE.select(burnAll, p.collateral, FHE.asEuint64(0));
        ebool _safeSub130 = FHE.ge(p.minted, actualBurn);
        p.minted = FHE.select(_safeSub130, FHE.sub(p.minted, actualBurn), FHE.asEuint64(0));
        ebool _safeSub131 = FHE.ge(p.collateral, collateralReturn);
        p.collateral = FHE.select(_safeSub131, FHE.sub(p.collateral, collateralReturn), FHE.asEuint64(0));
        if (FHE.isInitialized(burnAll)) p.active = false;
        ebool _safeSub132 = FHE.ge(_totalMinted, actualBurn);
        _totalMinted = FHE.select(_safeSub132, FHE.sub(_totalMinted, actualBurn), FHE.asEuint64(0));
        ebool _safeSub133 = FHE.ge(_totalCollateral, collateralReturn);
        _totalCollateral = FHE.select(_safeSub133, FHE.sub(_totalCollateral, collateralReturn), FHE.asEuint64(0));
        FHE.allowThis(p.minted);
        FHE.allowThis(p.collateral);
        FHE.allow(collateralReturn, msg.sender);
        FHE.allowThis(_totalMinted);
        FHE.allowThis(_totalCollateral);
        emit PositionClosed(msg.sender);
    }

    function liquidate(address user, uint64 oraclePricePlaintext) external onlyOwner nonReentrant {
        SynthPosition storage p = positions[user];
        require(p.active, "No position");
        euint64 collateralValue = oraclePricePlaintext > 0 ? FHE.div(p.collateral, oraclePricePlaintext) : FHE.asEuint64(0);
        euint64 requiredCollateral = FHE.div(FHE.mul(p.minted, _minRatioBps), 10000);
        ebool undercollateralized = FHE.lt(collateralValue, requiredCollateral);
        if (FHE.isInitialized(undercollateralized)) {
            p.active = false;
            ebool _safeSub134 = FHE.ge(_totalCollateral, p.collateral);
            _totalCollateral = FHE.select(_safeSub134, FHE.sub(_totalCollateral, p.collateral), FHE.asEuint64(0));
            ebool _safeSub135 = FHE.ge(_totalMinted, p.minted);
            _totalMinted = FHE.select(_safeSub135, FHE.sub(_totalMinted, p.minted), FHE.asEuint64(0));
            FHE.allow(p.collateral, owner());
            FHE.allowThis(_totalCollateral);
            FHE.allowThis(_totalMinted);
            emit Liquidated(user);
        }
    }

    function allowPositionData(address viewer) external {
        FHE.allow(positions[msg.sender].collateral, viewer);
        FHE.allow(positions[msg.sender].minted, viewer);
    }
}
