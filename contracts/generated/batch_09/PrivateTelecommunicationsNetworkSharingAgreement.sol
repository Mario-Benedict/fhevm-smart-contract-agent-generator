// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateTelecommunicationsNetworkSharingAgreement
/// @notice Encrypted telecom network sharing (MORAN/MOCN): hidden cost sharing formulas,
///         confidential traffic load ratios, private spectrum contribution valuation,
///         and encrypted energy savings distribution between MNOs.
contract PrivateTelecommunicationsNetworkSharingAgreement is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum SharingModel { MORAN, MOCN, ActiveSharing, PassiveSharing, FullNetworkSharing }
    enum TechnologyGeneration { G2, G3, G4LTE, G5NR }

    struct NetworkSharingDeal {
        address mno1;
        address mno2;
        SharingModel sharingModel;
        TechnologyGeneration generation;
        string siteRegionRef;
        euint32 sitesShared;           // encrypted shared site count
        euint64 infrastructureCostUSD; // encrypted total infra cost
        euint16 mno1CostShareBps;      // encrypted MNO1 cost share
        euint16 mno2CostShareBps;      // encrypted MNO2 cost share
        euint64 mno1TrafficLoadBps;    // encrypted MNO1 traffic ratio
        euint64 spectrumContribValueUSD; // encrypted spectrum contribution
        euint64 energySavingsUSD;      // encrypted energy savings
        euint64 annualSettlementUSD;   // encrypted net settlement
        uint256 agreementStart;
        uint256 agreementEnd;
    }

    mapping(uint256 => NetworkSharingDeal) private deals;
    mapping(address => bool) public isNetworkRegulator;

    uint256 public dealCount;
    euint64 private _totalInfrastructureSavingsUSD;
    euint64 private _totalEnergySavingsUSD;

    event DealRegistered(uint256 indexed id, SharingModel model, TechnologyGeneration gen);
    event SettlementExecuted(uint256 indexed id, uint256 executedAt);

    modifier onlyNetworkRegulator() {
        require(isNetworkRegulator[msg.sender] || msg.sender == owner(), "Not network regulator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalInfrastructureSavingsUSD = FHE.asEuint64(0);
        _totalEnergySavingsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalInfrastructureSavingsUSD);
        FHE.allowThis(_totalEnergySavingsUSD);
        isNetworkRegulator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addNetworkRegulator(address r) external onlyOwner { isNetworkRegulator[r] = true; }

    function registerDeal(
        address mno2, SharingModel sharingModel, TechnologyGeneration generation,
        string calldata siteRegionRef,
        externalEuint32 encSites, bytes calldata sProof,
        externalEuint64 encInfraCost, bytes calldata icProof,
        externalEuint16 encMNO1Share, bytes calldata m1Proof,
        externalEuint16 encMNO2Share, bytes calldata m2Proof,
        externalEuint64 encSpectrum, bytes calldata spProof,
        externalEuint64 encEnergySavings, bytes calldata esProof,
        uint256 termDays
    ) external whenNotPaused returns (uint256 id) {
        euint32 sites = FHE.fromExternal(encSites, sProof);
        euint64 infraCost = FHE.fromExternal(encInfraCost, icProof);
        euint16 mno1Share = FHE.fromExternal(encMNO1Share, m1Proof);
        euint16 mno2Share = FHE.fromExternal(encMNO2Share, m2Proof);
        euint64 spectrum = FHE.fromExternal(encSpectrum, spProof);
        euint64 energySavings = FHE.fromExternal(encEnergySavings, esProof);
        id = dealCount++;
        NetworkSharingDeal storage _s0 = deals[id];
        _s0.mno1 = msg.sender;
        _s0.mno2 = mno2;
        _s0.sharingModel = sharingModel;
        _s0.generation = generation;
        _s0.siteRegionRef = siteRegionRef;
        _s0.sitesShared = sites;
        _s0.infrastructureCostUSD = infraCost;
        _s0.mno1CostShareBps = mno1Share;
        _s0.mno2CostShareBps = mno2Share;
        _s0.mno1TrafficLoadBps = FHE.asEuint64(0);
        _s0.spectrumContribValueUSD = spectrum;
        _s0.energySavingsUSD = energySavings;
        _s0.annualSettlementUSD = FHE.asEuint64(0);
        _s0.agreementStart = block.timestamp;
        _s0.agreementEnd = block.timestamp + termDays * 1 days;
        _totalInfrastructureSavingsUSD = FHE.add(_totalInfrastructureSavingsUSD, FHE.div(infraCost, 2));
        _totalEnergySavingsUSD = FHE.add(_totalEnergySavingsUSD, energySavings);
        FHE.allowThis(deals[id].sitesShared); FHE.allow(deals[id].sitesShared, msg.sender); FHE.allow(deals[id].sitesShared, mno2);
        FHE.allowThis(deals[id].infrastructureCostUSD); FHE.allow(deals[id].infrastructureCostUSD, msg.sender); FHE.allow(deals[id].infrastructureCostUSD, mno2);
        FHE.allowThis(deals[id].mno1CostShareBps); FHE.allow(deals[id].mno1CostShareBps, msg.sender);
        FHE.allowThis(deals[id].mno2CostShareBps); FHE.allow(deals[id].mno2CostShareBps, mno2);
        FHE.allowThis(deals[id].spectrumContribValueUSD);
        FHE.allowThis(deals[id].energySavingsUSD); FHE.allow(deals[id].energySavingsUSD, msg.sender); FHE.allow(deals[id].energySavingsUSD, mno2);
        FHE.allowThis(deals[id].annualSettlementUSD);
        FHE.allowThis(_totalInfrastructureSavingsUSD);
        FHE.allowThis(_totalEnergySavingsUSD);
        emit DealRegistered(id, sharingModel, generation);
    }

    function executeAnnualSettlement(
        uint256 dealId,
        externalEuint64 encSettlement, bytes calldata proof
    ) external onlyNetworkRegulator nonReentrant {
        NetworkSharingDeal storage d = deals[dealId];
        d.annualSettlementUSD = FHE.fromExternal(encSettlement, proof);
        FHE.allowThis(d.annualSettlementUSD); FHE.allow(d.annualSettlementUSD, d.mno1); FHE.allow(d.annualSettlementUSD, d.mno2);
        emit SettlementExecuted(dealId, block.timestamp);
    }

    function allowIndustryStats(address viewer) external onlyOwner {
        FHE.allow(_totalInfrastructureSavingsUSD, viewer);
        FHE.allow(_totalEnergySavingsUSD, viewer);
    }
}
