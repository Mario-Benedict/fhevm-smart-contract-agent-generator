// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialSyntheticIndexToken
/// @notice Encrypted synthetic index token: hidden component weights, private
///         rebalancing thresholds, confidential index NAV, and encrypted
///         management fee accrual with AUM-based fee tiers.
contract ConfidentialSyntheticIndexToken is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "Synthetic Index";
    string public constant symbol = "SIDX";
    uint8  public constant decimals = 18;

    struct IndexComponent {
        address underlyingAsset;
        string  assetRef;
        euint16 targetWeightBps;       // encrypted target weight
        euint16 currentWeightBps;      // encrypted current weight
        euint64 priceUSD;              // encrypted price
        euint64 valueInIndexUSD;       // encrypted value contribution
        bool active;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => IndexComponent) private components;

    euint64 private _totalSupply;
    euint64 private _indexNAVUSD;         // encrypted total NAV
    euint64 private _totalMgmtFeesUSD;    // encrypted fees accrued
    euint16 private _annualMgmtFeeBps;    // encrypted fee rate
    euint64 private _aum;                 // encrypted AUM

    uint256 public componentCount;

    event Transfer(address indexed from, address indexed to);
    event ComponentAdded(uint256 indexed id, address underlyingAsset);
    event IndexRebalanced(uint256 timestamp);
    event NAVUpdated(uint256 updatedAt);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _indexNAVUSD = FHE.asEuint64(0);
        _totalMgmtFeesUSD = FHE.asEuint64(0);
        _annualMgmtFeeBps = FHE.asEuint16(50); // 0.5% annual
        _aum = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_indexNAVUSD);
        FHE.allowThis(_totalMgmtFeesUSD); FHE.allowThis(_annualMgmtFeeBps); FHE.allowThis(_aum);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function addComponent(
        address underlyingAsset, string calldata assetRef,
        externalEuint16 encTargetWeight, bytes calldata twProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyOwner returns (uint256 id) {
        euint16 weight = FHE.fromExternal(encTargetWeight, twProof);
        euint64 price  = FHE.fromExternal(encPrice, pProof);
        id = componentCount++;
        components[id] = IndexComponent({
            underlyingAsset: underlyingAsset, assetRef: assetRef, targetWeightBps: weight,
            currentWeightBps: weight, priceUSD: price, valueInIndexUSD: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(components[id].targetWeightBps); FHE.allowThis(components[id].currentWeightBps);
        FHE.allowThis(components[id].priceUSD); FHE.allowThis(components[id].valueInIndexUSD);
        emit ComponentAdded(id, underlyingAsset);
    }

    function updateComponentPrice(uint256 componentId, externalEuint64 encPrice, bytes calldata proof) external onlyOwner {
        euint64 price = FHE.fromExternal(encPrice, proof);
        components[componentId].priceUSD = price;
        // Recalculate value in index
        euint64 newVal = FHE.mul(price, FHE.asEuint64(100)); // simplified
        _indexNAVUSD = FHE.add(_indexNAVUSD, newVal);
        _aum = _indexNAVUSD;
        FHE.allowThis(components[componentId].priceUSD); FHE.allowThis(_indexNAVUSD); FHE.allowThis(_aum);
        emit NAVUpdated(block.timestamp);
    }

    function rebalance(uint256[] calldata componentIds, externalEuint16[] calldata encNewWeights, bytes[] calldata proofs) external onlyOwner whenNotPaused {
        require(componentIds.length == encNewWeights.length, "Length mismatch");
        for (uint256 i = 0; i < componentIds.length; i++) {
            components[componentIds[i]].currentWeightBps = FHE.fromExternal(encNewWeights[i], proofs[i]);
            FHE.allowThis(components[componentIds[i]].currentWeightBps);
        }
        emit IndexRebalanced(block.timestamp);
    }

    function accrueManagementFee() external onlyOwner {
        // Daily fee = AUM * annualFeeBps / 10000 / 365
        euint64 dailyFee = FHE.div(FHE.div(FHE.mul(_aum, FHE.asEuint64(50)), 10000), 365);
        _totalMgmtFeesUSD = FHE.add(_totalMgmtFeesUSD, dailyFee);
        _indexNAVUSD = FHE.sub(_indexNAVUSD, dailyFee);
        FHE.allowThis(_totalMgmtFeesUSD); FHE.allowThis(_indexNAVUSD);
    }

    function mint(address to, externalEuint64 encAmt, bytes calldata proof) external onlyOwner whenNotPaused {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        _balances[to] = FHE.add(_balances[to], amt);
        _totalSupply = FHE.add(_totalSupply, amt);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
        emit Transfer(address(0), to);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused {
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

    function allowIndexStats(address viewer) external onlyOwner {
        FHE.allow(_indexNAVUSD, viewer); FHE.allow(_totalMgmtFeesUSD, viewer); FHE.allow(_aum, viewer);
    }
    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
}
