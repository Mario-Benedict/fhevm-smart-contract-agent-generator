// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateOffshoreOilFieldProductionSharing
/// @notice Encrypted offshore oil field PSA: hidden daily production barrels, confidential
///         cost oil recovery, private profit oil splits between NOC and IOC,
///         and encrypted royalty escalation at production thresholds.
contract PrivateOffshoreOilFieldProductionSharing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FieldType { Deepwater, UltraDeep, ShallowOffshore, SyntheticOilSands, Shale }
    enum PSAStatus { Exploration, Development, Production, Decommissioning }

    struct PSAContract {
        address ioc;
        address noc;
        FieldType fieldType;
        string blockRef;
        string country;
        euint64 dailyProductionBOPD;   // encrypted daily barrels
        euint64 cumulativeProductionBO; // encrypted cumulative barrels
        euint64 costOilRecoveredUSD;   // encrypted cost oil recovered
        euint64 profitOilNOCShareBps;  // encrypted NOC profit oil share
        euint64 profitOilIOCShareBps;  // encrypted IOC profit oil share
        euint64 royaltyRateBps;        // encrypted royalty rate
        euint64 totalRoyaltyPaidUSD;   // encrypted royalties paid
        euint64 oilPricePerBBLUSD;     // encrypted oil price
        PSAStatus status;
        uint256 signedAt;
        uint256 expiryDate;
    }

    mapping(uint256 => PSAContract) private psas;
    mapping(address => bool) public isEnergyMinistry;

    uint256 public psaCount;
    euint64 private _totalProductionRevUSD;
    euint64 private _totalRoyaltyCollectedUSD;

    event PSARegistered(uint256 indexed id, FieldType fieldType, string blockRef);
    event ProductionUpdated(uint256 indexed id, uint256 updatedAt);
    event RoyaltySettled(uint256 indexed id, uint256 settledAt);

    modifier onlyEnergyMinistry() {
        require(isEnergyMinistry[msg.sender] || msg.sender == owner(), "Not energy ministry");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalProductionRevUSD = FHE.asEuint64(0);
        _totalRoyaltyCollectedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalProductionRevUSD);
        FHE.allowThis(_totalRoyaltyCollectedUSD);
        isEnergyMinistry[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addEnergyMinistry(address em) external onlyOwner { isEnergyMinistry[em] = true; }

    function registerPSA(
        address ioc, address noc, FieldType fieldType, string calldata blockRef, string calldata country,
        externalEuint64 encProfNOC, bytes calldata nocProof,
        externalEuint64 encProfIOC, bytes calldata iocProof,
        externalEuint64 encRoyalty, bytes calldata royProof,
        uint256 termDays
    ) external onlyEnergyMinistry whenNotPaused returns (uint256 id) {
        euint64 profNOC = FHE.fromExternal(encProfNOC, nocProof);
        euint64 profIOC = FHE.fromExternal(encProfIOC, iocProof);
        euint64 royalty = FHE.fromExternal(encRoyalty, royProof);
        id = psaCount++;
        PSAContract storage _s0 = psas[id];
        _s0.ioc = ioc;
        _s0.noc = noc;
        _s0.fieldType = fieldType;
        _s0.blockRef = blockRef;
        _s0.country = country;
        _s0.dailyProductionBOPD = FHE.asEuint64(0);
        _s0.cumulativeProductionBO = FHE.asEuint64(0);
        _s0.costOilRecoveredUSD = FHE.asEuint64(0);
        _s0.profitOilNOCShareBps = profNOC;
        _s0.profitOilIOCShareBps = profIOC;
        _s0.royaltyRateBps = royalty;
        _s0.totalRoyaltyPaidUSD = FHE.asEuint64(0);
        _s0.oilPricePerBBLUSD = FHE.asEuint64(0);
        _s0.status = PSAStatus.Exploration;
        _s0.signedAt = block.timestamp;
        _s0.expiryDate = block.timestamp + termDays * 1 days;
        FHE.allowThis(psas[id].profitOilNOCShareBps); FHE.allow(psas[id].profitOilNOCShareBps, noc);
        FHE.allowThis(psas[id].profitOilIOCShareBps); FHE.allow(psas[id].profitOilIOCShareBps, ioc);
        FHE.allowThis(psas[id].royaltyRateBps); FHE.allow(psas[id].royaltyRateBps, noc);
        FHE.allowThis(psas[id].dailyProductionBOPD); FHE.allow(psas[id].dailyProductionBOPD, ioc); FHE.allow(psas[id].dailyProductionBOPD, noc);
        FHE.allowThis(psas[id].cumulativeProductionBO); FHE.allow(psas[id].cumulativeProductionBO, noc);
        FHE.allowThis(psas[id].totalRoyaltyPaidUSD);
        emit PSARegistered(id, fieldType, blockRef);
    }

    function updateProduction(
        uint256 psaId,
        externalEuint64 encDailyProd, bytes calldata dpProof,
        externalEuint64 encOilPrice, bytes calldata opProof
    ) external nonReentrant {
        PSAContract storage p = psas[psaId];
        require(msg.sender == p.ioc || isEnergyMinistry[msg.sender], "Not authorized");
        euint64 dailyProd = FHE.fromExternal(encDailyProd, dpProof);
        euint64 oilPrice = FHE.fromExternal(encOilPrice, opProof);
        p.dailyProductionBOPD = dailyProd;
        p.oilPricePerBBLUSD = oilPrice;
        p.cumulativeProductionBO = FHE.add(p.cumulativeProductionBO, dailyProd);
        euint64 dailyRevenue = FHE.mul(dailyProd, oilPrice); // [arithmetic_overflow_underflow]
        euint64 oilPriceScaled = FHE.mul(oilPrice, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        _totalProductionRevUSD = FHE.add(_totalProductionRevUSD, dailyRevenue);
        FHE.allowThis(p.dailyProductionBOPD); FHE.allow(p.dailyProductionBOPD, p.ioc); FHE.allow(p.dailyProductionBOPD, p.noc);
        FHE.allowThis(p.oilPricePerBBLUSD); FHE.allow(p.oilPricePerBBLUSD, p.ioc); FHE.allow(p.oilPricePerBBLUSD, p.noc);
        FHE.allowThis(p.cumulativeProductionBO); FHE.allow(p.cumulativeProductionBO, p.noc);
        FHE.allowThis(_totalProductionRevUSD);
        emit ProductionUpdated(psaId, block.timestamp);
    }

    function settleRoyalty(
        uint256 psaId,
        externalEuint64 encRoyaltyAmt, bytes calldata proof
    ) external onlyEnergyMinistry nonReentrant {
        PSAContract storage p = psas[psaId];
        euint64 royaltyAmt = FHE.fromExternal(encRoyaltyAmt, proof);
        p.totalRoyaltyPaidUSD = FHE.add(p.totalRoyaltyPaidUSD, royaltyAmt);
        _totalRoyaltyCollectedUSD = FHE.add(_totalRoyaltyCollectedUSD, royaltyAmt);
        FHE.allowThis(p.totalRoyaltyPaidUSD); FHE.allow(p.totalRoyaltyPaidUSD, p.noc); FHE.allow(p.totalRoyaltyPaidUSD, p.ioc);
        FHE.allowThis(_totalRoyaltyCollectedUSD);
        emit RoyaltySettled(psaId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalProductionRevUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalProductionRevUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltyCollectedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltyCollectedUSD, viewer);
    }
}
