// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedFishingQuotaTrading
/// @notice Fisheries quota trading: encrypted catch allowances, encrypted species quotas,
///         and traceable provenance for sustainable fishing compliance.
contract EncryptedFishingQuotaTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FishSpecies { AtlanticCod, Tuna, Salmon, Halibut, Pollock, Herring, Shrimp }
    enum QuotaStatus { Assigned, Listed, Transferred, Expired, Suspended }

    struct FishingVessel {
        address owner;
        string vesselName;
        string imoNumber;
        string flagState;
        euint32 grossTonnage;           // encrypted vessel tonnage
        euint32 complianceScore;        // encrypted RFMO compliance score
        bool licensed;
    }

    struct CatchQuota {
        uint256 vesselId;
        FishSpecies species;
        string fishingZone;
        euint64 allowedTonnes;          // encrypted total annual allowance
        euint64 caughtTonnes;           // encrypted actual catch to date
        euint64 remainingTonnes;        // encrypted remaining quota
        euint64 listedPriceCentsPerT;   // encrypted price if listed
        uint256 seasonEnd;
        QuotaStatus status;
    }

    struct CatchRecord {
        uint256 quotaId;
        euint32 catchAmountTonnes;      // encrypted catch report
        string portOfLanding;
        uint256 timestamp;
        bool verified;
    }

    mapping(uint256 => FishingVessel) private vessels;
    mapping(uint256 => CatchQuota) private quotas;
    mapping(uint256 => CatchRecord[]) private catchRecords;
    mapping(address => uint256) public ownerToVessel;
    mapping(address => bool) public isFisheriesAuthority;

    uint256 public vesselCount;
    uint256 public quotaCount;
    euint64 private _totalQuotaAllowanceT;
    euint64 private _totalCaughtT;
    euint64 private _totalQuotaTradeValueCents;

    event VesselRegistered(uint256 indexed id, string name, string imo);
    event QuotaAssigned(uint256 indexed id, FishSpecies species, uint256 vesselId);
    event QuotaListed(uint256 indexed id, uint256 vesselId);
    event QuotaTransferred(uint256 indexed id, address newOwner);
    event CatchReported(uint256 indexed quotaId, uint256 recordIndex);

    modifier onlyAuthority() {
        require(isFisheriesAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalQuotaAllowanceT = FHE.asEuint64(0);
        _totalCaughtT = FHE.asEuint64(0);
        _totalQuotaTradeValueCents = FHE.asEuint64(0);
        FHE.allowThis(_totalQuotaAllowanceT);
        FHE.allowThis(_totalCaughtT);
        FHE.allowThis(_totalQuotaTradeValueCents);
        isFisheriesAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isFisheriesAuthority[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerVessel(
        string calldata name, string calldata imo, string calldata flagState,
        externalEuint32 encTonnage, bytes calldata tProof,
        externalEuint32 encCompliance, bytes calldata cProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 tonnage = FHE.fromExternal(encTonnage, tProof);
        euint32 compliance = FHE.fromExternal(encCompliance, cProof);
        id = vesselCount++;
        vessels[id] = FishingVessel({
            owner: msg.sender, vesselName: name, imoNumber: imo, flagState: flagState,
            grossTonnage: tonnage, complianceScore: compliance, licensed: false
        });
        ownerToVessel[msg.sender] = id;
        FHE.allowThis(vessels[id].grossTonnage); FHE.allow(vessels[id].grossTonnage, msg.sender);
        FHE.allowThis(vessels[id].complianceScore); FHE.allow(vessels[id].complianceScore, msg.sender);
        emit VesselRegistered(id, name, imo);
    }

    function licenseVessel(uint256 vesselId) external onlyAuthority { vessels[vesselId].licensed = true; }

    function assignQuota(
        uint256 vesselId, FishSpecies species, string calldata zone,
        externalEuint64 encAllowance, bytes calldata aProof,
        uint256 seasonDays
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        require(vessels[vesselId].licensed, "Vessel not licensed");
        euint64 allowance = FHE.fromExternal(encAllowance, aProof);
        id = quotaCount++;
        quotas[id] = CatchQuota({
            vesselId: vesselId, species: species, fishingZone: zone,
            allowedTonnes: allowance, caughtTonnes: FHE.asEuint64(0),
            remainingTonnes: allowance, listedPriceCentsPerT: FHE.asEuint64(0),
            seasonEnd: block.timestamp + seasonDays * 1 days,
            status: QuotaStatus.Assigned
        });
        _totalQuotaAllowanceT = FHE.add(_totalQuotaAllowanceT, allowance);
        FHE.allowThis(quotas[id].allowedTonnes); FHE.allow(quotas[id].allowedTonnes, vessels[vesselId].owner);
        FHE.allowThis(quotas[id].caughtTonnes); FHE.allow(quotas[id].caughtTonnes, vessels[vesselId].owner);
        FHE.allowThis(quotas[id].remainingTonnes); FHE.allow(quotas[id].remainingTonnes, vessels[vesselId].owner);
        FHE.allowThis(quotas[id].listedPriceCentsPerT);
        FHE.allowThis(_totalQuotaAllowanceT);
        emit QuotaAssigned(id, species, vesselId);
    }

    function reportCatch(
        uint256 quotaId, string calldata port,
        externalEuint32 encCatch, bytes calldata proof
    ) external nonReentrant {
        CatchQuota storage q = quotas[quotaId];
        require(vessels[q.vesselId].owner == msg.sender && q.status == QuotaStatus.Assigned, "Not vessel owner");
        require(block.timestamp < q.seasonEnd, "Season ended");
        euint32 catchAmt = FHE.fromExternal(encCatch, proof);
        ebool withinQuota = FHE.le(FHE.add(q.caughtTonnes, FHE.asEuint64(0)), q.remainingTonnes);
        q.caughtTonnes = FHE.add(q.caughtTonnes, FHE.asEuint64(0));
        q.remainingTonnes = FHE.sub(q.remainingTonnes, FHE.asEuint64(0));
        _totalCaughtT = FHE.add(_totalCaughtT, FHE.asEuint64(0));
        catchRecords[quotaId].push(CatchRecord({
            quotaId: quotaId, catchAmountTonnes: catchAmt,
            portOfLanding: port, timestamp: block.timestamp, verified: false
        }));
        FHE.allowThis(catchAmt); FHE.allow(catchAmt, owner());
        FHE.allowThis(q.caughtTonnes);
        FHE.allowThis(q.remainingTonnes);
        FHE.allowThis(_totalCaughtT);
        emit CatchReported(quotaId, catchRecords[quotaId].length - 1);
    }

    function listQuota(uint256 quotaId, externalEuint64 encPrice, bytes calldata proof) external {
        CatchQuota storage q = quotas[quotaId];
        require(vessels[q.vesselId].owner == msg.sender && q.status == QuotaStatus.Assigned, "Not authorized");
        q.listedPriceCentsPerT = FHE.fromExternal(encPrice, proof);
        q.status = QuotaStatus.Listed;
        FHE.allowThis(q.listedPriceCentsPerT);
        emit QuotaListed(quotaId, q.vesselId);
    }

    function transferQuota(uint256 quotaId, address newOwner) external nonReentrant whenNotPaused {
        CatchQuota storage q = quotas[quotaId];
        require(vessels[q.vesselId].owner == msg.sender && q.status == QuotaStatus.Listed, "Not listed");
        address prev = vessels[q.vesselId].owner;
        vessels[q.vesselId].owner = newOwner;
        q.status = QuotaStatus.Transferred;
        _totalQuotaTradeValueCents = FHE.add(_totalQuotaTradeValueCents, q.listedPriceCentsPerT);
        FHE.allow(q.remainingTonnes, newOwner);
        FHE.allowThis(_totalQuotaTradeValueCents);
        emit QuotaTransferred(quotaId, newOwner);
    }

    function verifyRecord(uint256 quotaId, uint256 recordIndex) external onlyAuthority {
        catchRecords[quotaId][recordIndex].verified = true;
    }

    function allowFisheriesStats(address viewer) external onlyOwner {
        FHE.allow(_totalQuotaAllowanceT, viewer);
        FHE.allow(_totalCaughtT, viewer);
        FHE.allow(_totalQuotaTradeValueCents, viewer);
    }
}
