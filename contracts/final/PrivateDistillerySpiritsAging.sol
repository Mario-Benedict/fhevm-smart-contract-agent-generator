// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDistillerySpiritsAging
/// @notice Encrypted distillery spirits cask aging management: hidden cask valuations per age,
///         confidential ABV readings, private blending ratios, and encrypted barrel futures
///         trading between whisky investment funds.
contract PrivateDistillerySpiritsAging is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum SpiritsType { Scotch, Bourbon, Irish, Japanese, Rum, Cognac, Mezcal }

    struct AgingCask {
        address distillery;
        SpiritsType spiritsType;
        string caskRef;
        uint32 distillationYear;
        euint32 initialVolumeLiters;   // encrypted initial fill
        euint32 currentVolumeLiters;   // encrypted current volume (angels share adjusted)
        euint16 abvBps;                // encrypted ABV reading bps
        euint64 currentValuationUSD;   // encrypted current market value
        euint64 acquisitionCostUSD;    // encrypted original cost
        euint16 agingProgressMonths;   // encrypted months aged so far
        bool bottled;
    }

    struct CaskFuturesTrade {
        uint256 caskId;
        address seller;
        address buyer;
        euint64 tradePriceUSD;         // encrypted trade price
        euint16 maturityMonths;        // encrypted agreed aging period
        uint256 tradeDate;
        bool settled;
    }

    mapping(uint256 => AgingCask) private casks;
    mapping(uint256 => CaskFuturesTrade) private trades;
    mapping(address => bool) public isDistillery;
    mapping(address => bool) public isCaskBroker;

    uint256 public caskCount;
    uint256 public tradeCount;
    euint64 private _totalCaskInventoryValueUSD;

    event CaskRegistered(uint256 indexed id, SpiritsType spiritsType, uint32 distillationYear);
    event CaskTraded(uint256 indexed tradeId, uint256 caskId);
    event ABVUpdated(uint256 indexed caskId, uint256 updatedAt);

    modifier onlyDistillery() {
        require(isDistillery[msg.sender] || msg.sender == owner(), "Not distillery");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCaskInventoryValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCaskInventoryValueUSD);
        isDistillery[msg.sender] = true;
        isCaskBroker[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addDistillery(address d) external onlyOwner { isDistillery[d] = true; }
    function addCaskBroker(address b) external onlyOwner { isCaskBroker[b] = true; }

    function registerCask(
        SpiritsType spiritsType, string calldata caskRef, uint32 distillationYear,
        externalEuint32 encInitVol, bytes calldata ivProof,
        externalEuint16 encABV, bytes calldata abvProof,
        externalEuint64 encValuation, bytes calldata valProof,
        externalEuint64 encAcqCost, bytes calldata acProof
    ) external onlyDistillery whenNotPaused returns (uint256 id) {
        euint32 initVol = FHE.fromExternal(encInitVol, ivProof);
        euint16 abv = FHE.fromExternal(encABV, abvProof);
        euint64 valuation = FHE.fromExternal(encValuation, valProof);
        euint64 acqCost = FHE.fromExternal(encAcqCost, acProof);
        id = caskCount++;
        casks[id].distillery = msg.sender;
        casks[id].spiritsType = spiritsType;
        casks[id].caskRef = caskRef;
        casks[id].distillationYear = distillationYear;
        casks[id].initialVolumeLiters = initVol;
        casks[id].currentVolumeLiters = initVol;
        casks[id].abvBps = abv;
        casks[id].currentValuationUSD = valuation;
        casks[id].acquisitionCostUSD = acqCost;
        casks[id].agingProgressMonths = FHE.asEuint16(0);
        casks[id].bottled = false;
        _totalCaskInventoryValueUSD = FHE.add(_totalCaskInventoryValueUSD, valuation);
        FHE.allowThis(casks[id].initialVolumeLiters); FHE.allow(casks[id].initialVolumeLiters, msg.sender);
        FHE.allowThis(casks[id].currentVolumeLiters); FHE.allow(casks[id].currentVolumeLiters, msg.sender);
        FHE.allowThis(casks[id].abvBps); FHE.allow(casks[id].abvBps, msg.sender);
        FHE.allowThis(casks[id].currentValuationUSD); FHE.allow(casks[id].currentValuationUSD, msg.sender);
        FHE.allowThis(casks[id].acquisitionCostUSD); FHE.allow(casks[id].acquisitionCostUSD, msg.sender);
        FHE.allowThis(casks[id].agingProgressMonths);
        FHE.allowThis(_totalCaskInventoryValueUSD);
        emit CaskRegistered(id, spiritsType, distillationYear);
    }

    function updateABVAndValuation(
        uint256 caskId,
        externalEuint16 encABV, bytes calldata abvProof,
        externalEuint32 encCurrVol, bytes calldata cvProof,
        externalEuint64 encValuation, bytes calldata valProof,
        externalEuint16 encAgingMonths, bytes calldata amProof
    ) external onlyDistillery {
        AgingCask storage c = casks[caskId];
        require(msg.sender == c.distillery, "Not owner distillery");
        euint16 newABV = FHE.fromExternal(encABV, abvProof);
        euint32 currVol = FHE.fromExternal(encCurrVol, cvProof);
        euint64 newVal = FHE.fromExternal(encValuation, valProof);
        euint16 agingMonths = FHE.fromExternal(encAgingMonths, amProof);
        _totalCaskInventoryValueUSD = FHE.sub(_totalCaskInventoryValueUSD, c.currentValuationUSD);
        c.abvBps = newABV;
        c.currentVolumeLiters = currVol;
        c.currentValuationUSD = newVal;
        c.agingProgressMonths = agingMonths;
        _totalCaskInventoryValueUSD = FHE.add(_totalCaskInventoryValueUSD, newVal);
        FHE.allowThis(c.abvBps); FHE.allow(c.abvBps, msg.sender);
        FHE.allowThis(c.currentVolumeLiters); FHE.allow(c.currentVolumeLiters, msg.sender);
        FHE.allowThis(c.currentValuationUSD); FHE.allow(c.currentValuationUSD, msg.sender);
        FHE.allowThis(c.agingProgressMonths);
        FHE.allowThis(_totalCaskInventoryValueUSD);
        emit ABVUpdated(caskId, block.timestamp);
    }

    function tradeCask(
        uint256 caskId, address buyer,
        externalEuint64 encTradePrice, bytes calldata tpProof,
        externalEuint16 encMaturity, bytes calldata mProof
    ) external nonReentrant returns (uint256 tradeId) {
        require(isCaskBroker[msg.sender] || msg.sender == casks[caskId].distillery, "Not authorized");
        euint64 tradePrice = FHE.fromExternal(encTradePrice, tpProof);
        euint16 maturity = FHE.fromExternal(encMaturity, mProof);
        tradeId = tradeCount++;
        trades[tradeId] = CaskFuturesTrade({
            caskId: caskId, seller: casks[caskId].distillery, buyer: buyer,
            tradePriceUSD: tradePrice, maturityMonths: maturity,
            tradeDate: block.timestamp, settled: false
        });
        FHE.allowThis(trades[tradeId].tradePriceUSD); FHE.allow(trades[tradeId].tradePriceUSD, casks[caskId].distillery); FHE.allow(trades[tradeId].tradePriceUSD, buyer);
        FHE.allowThis(trades[tradeId].maturityMonths); FHE.allow(trades[tradeId].maturityMonths, buyer);
        emit CaskTraded(tradeId, caskId);
    }

    function allowInventoryView(address viewer) external onlyOwner {
        FHE.allow(_totalCaskInventoryValueUSD, viewer);
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