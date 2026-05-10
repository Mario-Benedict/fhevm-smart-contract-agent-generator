// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialInsurancePremiumToken
/// @notice ERC20 insurance premium token: encrypted risk scores, private actuarial
///         calculations, hidden pooled reserves, and confidential claim payout scheduling.
contract ConfidentialInsurancePremiumToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Insurance Premium";
    string public constant symbol = "INSP";
    uint8  public constant decimals = 6;

    mapping(address => euint64) private _balances;
    mapping(address => euint16) private _riskScore;      // encrypted risk 0-10000
    mapping(address => euint64) private _premiumObligation; // encrypted required premium
    mapping(address => euint64) private _claimReserve;   // encrypted reserve allocated

    euint64 private _totalSupply;
    euint64 private _claimPool;
    euint64 private _reinsuranceReserve;

    event Transfer(address indexed from, address indexed to);
    event PolicyIssued(address indexed policyholder);
    event ClaimPaid(address indexed claimant, uint256 paidAt);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _claimPool = FHE.asEuint64(0);
        _reinsuranceReserve = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_claimPool); FHE.allowThis(_reinsuranceReserve);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issuePolicy(
        address policyholder,
        externalEuint16 encRisk,    bytes calldata rProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint64 encReserve, bytes calldata resProof,
        externalEuint64 encMint,    bytes calldata mProof
    ) external onlyOwner {
        euint16 risk     = FHE.fromExternal(encRisk, rProof);
        euint64 premium  = FHE.fromExternal(encPremium, pProof);
        euint64 reserve  = FHE.fromExternal(encReserve, resProof);
        euint64 mintAmt  = FHE.fromExternal(encMint, mProof);
        _riskScore[policyholder] = risk;
        _premiumObligation[policyholder] = premium;
        _claimReserve[policyholder] = reserve;
        if (!FHE.isInitialized(_balances[policyholder])) { _balances[policyholder] = FHE.asEuint64(0); FHE.allowThis(_balances[policyholder]); }
        _balances[policyholder] = FHE.add(_balances[policyholder], mintAmt);
        _claimPool = FHE.add(_claimPool, reserve);
        _reinsuranceReserve = FHE.add(_reinsuranceReserve, FHE.div(reserve, 4)); // 25% to reinsurance
        _totalSupply = FHE.add(_totalSupply, mintAmt);
        FHE.allowThis(_riskScore[policyholder]);
        FHE.allowThis(_premiumObligation[policyholder]); FHE.allow(_premiumObligation[policyholder], policyholder);
        FHE.allowThis(_claimReserve[policyholder]); FHE.allow(_claimReserve[policyholder], policyholder);
        FHE.allowThis(_balances[policyholder]); FHE.allow(_balances[policyholder], policyholder);
        FHE.allowThis(_claimPool); FHE.allowThis(_reinsuranceReserve); FHE.allowThis(_totalSupply);
        emit PolicyIssued(policyholder);
    }

    function payPremium(externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 effAmt = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub42 = FHE.ge(_balances[msg.sender], effAmt);
        _balances[msg.sender] = FHE.select(_safeSub42, FHE.sub(_balances[msg.sender], effAmt), FHE.asEuint64(0));
        _claimPool = FHE.add(_claimPool, effAmt);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_claimPool);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub43 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub43, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function settleClaim(address claimant, externalEuint64 encClaim, bytes calldata proof) external onlyOwner nonReentrant {
        euint64 claimAmt = FHE.fromExternal(encClaim, proof);
        ebool poolSufficient = FHE.ge(_claimPool, claimAmt);
        euint64 effClaim = FHE.select(poolSufficient, claimAmt, _claimPool);
        ebool _safeSub44 = FHE.ge(_claimPool, effClaim);
        _claimPool = FHE.select(_safeSub44, FHE.sub(_claimPool, effClaim), FHE.asEuint64(0));
        if (!FHE.isInitialized(_balances[claimant])) { _balances[claimant] = FHE.asEuint64(0); FHE.allowThis(_balances[claimant]); }
        _balances[claimant] = FHE.add(_balances[claimant], effClaim);
        FHE.allowThis(_claimPool);
        FHE.allowThis(_balances[claimant]); FHE.allow(_balances[claimant], claimant);
        emit ClaimPaid(claimant, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_claimPool, viewer); FHE.allow(_reinsuranceReserve, viewer); FHE.allow(_totalSupply, viewer);
    }
    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function riskScoreOf(address a) external view returns (euint16) { return _riskScore[a]; }
}
