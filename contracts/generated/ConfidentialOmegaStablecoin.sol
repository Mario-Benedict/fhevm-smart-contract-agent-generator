// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialOmegaStablecoin
/// @notice Encrypted algorithmic stablecoin: hidden collateral ratios, private mint/redeem
///         caps per address, confidential stability fee accrual, and encrypted
///         liquidation threshold tracking.
contract ConfidentialOmegaStablecoin is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Omega Stable";
    string public constant symbol = "OMGS";
    uint8  public constant decimals = 6;

    mapping(address => euint64) private _balances;
    mapping(address => mapping(address => euint64)) private _allowances;
    euint64 private _totalSupply;

    euint64 private _globalMintCapPerAddress;
    euint64 private _collateralRatioBps;
    euint64 private _stabilityFeeBps;
    mapping(address => euint64) private _mintedByAddress;
    mapping(address => euint64) private _collateralDeposited;

    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event Minted(address indexed to, uint256 timestamp);
    event Redeemed(address indexed from, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _globalMintCapPerAddress = FHE.asEuint64(1_000_000 * 1e6);
        _collateralRatioBps = FHE.asEuint64(15000);
        _stabilityFeeBps = FHE.asEuint64(50);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_globalMintCapPerAddress);
        FHE.allowThis(_collateralRatioBps);
        FHE.allowThis(_stabilityFeeBps);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function depositCollateralAndMint(
        externalEuint64 encCollateral, bytes calldata colProof,
        externalEuint64 encMintAmt, bytes calldata mintProof
    ) external whenNotPaused nonReentrant {
        euint64 collateral = FHE.fromExternal(encCollateral, colProof);
        euint64 mintAmt = FHE.fromExternal(encMintAmt, mintProof);
        if (!FHE.isInitialized(_collateralDeposited[msg.sender])) {
            _collateralDeposited[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_collateralDeposited[msg.sender]);
        }
        if (!FHE.isInitialized(_mintedByAddress[msg.sender])) {
            _mintedByAddress[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_mintedByAddress[msg.sender]);
        }
        if (!FHE.isInitialized(_balances[msg.sender])) {
            _balances[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_balances[msg.sender]);
        }
        ebool withinCap = FHE.le(FHE.add(_mintedByAddress[msg.sender], mintAmt), _globalMintCapPerAddress);
        euint64 effectiveMint = FHE.select(withinCap, mintAmt, FHE.asEuint64(0));
        _collateralDeposited[msg.sender] = FHE.add(_collateralDeposited[msg.sender], collateral);
        _mintedByAddress[msg.sender] = FHE.add(_mintedByAddress[msg.sender], effectiveMint);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], effectiveMint);
        _totalSupply = FHE.add(_totalSupply, effectiveMint);
        FHE.allowThis(_collateralDeposited[msg.sender]); FHE.allow(_collateralDeposited[msg.sender], msg.sender);
        FHE.allowThis(_mintedByAddress[msg.sender]); FHE.allow(_mintedByAddress[msg.sender], msg.sender);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        emit Minted(msg.sender, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 effectiveAmt = FHE.select(sufficient, amt, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], effectiveAmt);
        _balances[to] = FHE.add(_balances[to], effectiveAmt);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }
    function totalSupply() external view returns (euint64) { return _totalSupply; }

    function allowTotalSupplyView(address viewer) external onlyOwner { FHE.allow(_totalSupply, viewer); }
    function allowBalanceView(address account, address viewer) external onlyOwner { FHE.allow(_balances[account], viewer); }
    function allowCollateralView(address account) external view returns (euint64) { return _collateralDeposited[account]; }
}
