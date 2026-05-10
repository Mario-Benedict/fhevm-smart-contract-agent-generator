// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFisheryQuotaTrading
/// @notice Fishing quota trading system: encrypted Individual Transferable Quotas (ITQs),
///         encrypted species catch limits, encrypted vessel capacity ratings, and confidential sustainability scores.
contract EncryptedFisheryQuotaTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Species { COD, TUNA, SALMON, HALIBUT, SHRIMP, CRAB, LOBSTER }

    struct FishingVessel {
        string vesselName;
        string registrationNumber;
        address owner_;
        euint64 capacityTonnes;       // encrypted catch capacity
        euint64 sustainabilityScore;  // encrypted environmental score 0-1000
        euint64 bycatchRateBps;       // encrypted bycatch % 
        bool licensed;
    }

    struct Quota {
        uint256 vesselId;
        Species species;
        euint64 annualQuotaTonnes;    // encrypted annual quota
        euint64 usedTonnes;           // encrypted used this season
        euint64 quotaValueUSD;        // encrypted quota market value
        uint256 season;               // YYYY
        bool transferable;
    }

    struct QuotaTransfer {
        uint256 fromQuotaId;
        uint256 toVesselId;
        euint64 transferredTonnes;    // encrypted amount transferred
        euint64 priceUSD;             // encrypted transaction price
        address buyer;
        uint256 transferDate;
        bool approved;
    }

    mapping(uint256 => FishingVessel) private vessels;
    mapping(uint256 => Quota) private quotas;
    mapping(uint256 => QuotaTransfer) private transfers;
    uint256 public vesselCount;
    uint256 public quotaCount;
    uint256 public transferCount;
    euint64 private _totalQuotaIssuedTonnes;
    mapping(address => bool) public isFisheryManager;

    event VesselRegistered(uint256 indexed id, string name);
    event QuotaIssued(uint256 indexed id, uint256 vesselId, Species species);
    event CatchReported(uint256 indexed quotaId);
    event TransferRequested(uint256 indexed transferId, uint256 quotaId);
    event TransferApproved(uint256 indexed transferId);

    constructor() Ownable(msg.sender) {
        _totalQuotaIssuedTonnes = FHE.asEuint64(0);
        FHE.allowThis(_totalQuotaIssuedTonnes);
        isFisheryManager[msg.sender] = true;
    }

    function addManager(address m) external onlyOwner { isFisheryManager[m] = true; }

    function registerVessel(
        string calldata name, string calldata regNum,
        externalEuint64 encCapacity, bytes calldata cProof,
        externalEuint64 encSustainability, bytes calldata sProof
    ) external returns (uint256 id) {
        euint64 capacity = FHE.fromExternal(encCapacity, cProof);
        euint64 sustainability = FHE.fromExternal(encSustainability, sProof);
        id = vesselCount++;
        vessels[id] = FishingVessel({
            vesselName: name, registrationNumber: regNum, owner_: msg.sender,
            capacityTonnes: capacity, sustainabilityScore: sustainability,
            bycatchRateBps: FHE.asEuint64(0), licensed: false
        });
        FHE.allowThis(vessels[id].capacityTonnes);
        FHE.allowThis(vessels[id].sustainabilityScore);
        FHE.allowThis(vessels[id].bycatchRateBps);
        FHE.allow(vessels[id].sustainabilityScore, msg.sender);
        emit VesselRegistered(id, name);
    }

    function issueQuota(
        uint256 vesselId, Species species,
        externalEuint64 encQuota, bytes calldata qProof,
        externalEuint64 encValue, bytes calldata vProof,
        uint256 season
    ) external returns (uint256 quotaId) {
        require(isFisheryManager[msg.sender], "Not manager");
        euint64 quota = FHE.fromExternal(encQuota, qProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        quotaId = quotaCount++;
        quotas[quotaId] = Quota({
            vesselId: vesselId, species: species,
            annualQuotaTonnes: quota, usedTonnes: FHE.asEuint64(0),
            quotaValueUSD: value, season: season, transferable: true
        });
        _totalQuotaIssuedTonnes = FHE.add(_totalQuotaIssuedTonnes, quota);
        FHE.allowThis(quotas[quotaId].annualQuotaTonnes);
        FHE.allowThis(quotas[quotaId].usedTonnes);
        FHE.allowThis(quotas[quotaId].quotaValueUSD);
        FHE.allow(quotas[quotaId].annualQuotaTonnes, vessels[vesselId].owner_);
        FHE.allow(quotas[quotaId].usedTonnes, vessels[vesselId].owner_);
        FHE.allowThis(_totalQuotaIssuedTonnes);
        emit QuotaIssued(quotaId, vesselId, species);
    }

    function reportCatch(
        uint256 quotaId,
        externalEuint64 encCatch, bytes calldata proof,
        externalEuint64 encBycatch, bytes calldata bProof
    ) external {
        require(vessels[quotas[quotaId].vesselId].owner_ == msg.sender, "Not vessel owner");
        euint64 catch_ = FHE.fromExternal(encCatch, proof);
        euint64 bycatch = FHE.fromExternal(encBycatch, bProof);
        Quota storage q = quotas[quotaId];
        ebool withinQuota = FHE.le(FHE.add(q.usedTonnes, catch_), q.annualQuotaTonnes);
        euint64 actual = FHE.select(withinQuota, catch_, FHE.sub(q.annualQuotaTonnes, q.usedTonnes));
        q.usedTonnes = FHE.add(q.usedTonnes, actual);
        // Update bycatch rate
        vessels[q.vesselId].bycatchRateBps = bycatch;
        FHE.allowThis(q.usedTonnes);
        FHE.allow(q.usedTonnes, msg.sender);
        FHE.allowThis(vessels[q.vesselId].bycatchRateBps);
        emit CatchReported(quotaId);
    }

    function requestTransfer(
        uint256 quotaId, address buyer,
        externalEuint64 encTonnes, bytes calldata tProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external nonReentrant returns (uint256 transferId) {
        require(vessels[quotas[quotaId].vesselId].owner_ == msg.sender, "Not owner");
        require(quotas[quotaId].transferable, "Not transferable");
        euint64 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        ebool _safeSub230 = FHE.ge(quotas[quotaId].annualQuotaTonnes, quotas[quotaId].usedTonnes);
        euint64 remaining = FHE.select(_safeSub230, FHE.sub(quotas[quotaId].annualQuotaTonnes, quotas[quotaId].usedTonnes), FHE.asEuint64(0));
        ebool withinRemaining = FHE.le(tonnes, remaining);
        euint64 actualTonnes = FHE.select(withinRemaining, tonnes, remaining);
        transferId = transferCount++;
        transfers[transferId] = QuotaTransfer({
            fromQuotaId: quotaId, toVesselId: 0, transferredTonnes: actualTonnes,
            priceUSD: price, buyer: buyer, transferDate: block.timestamp, approved: false
        });
        FHE.allowThis(transfers[transferId].transferredTonnes);
        FHE.allowThis(transfers[transferId].priceUSD);
        emit TransferRequested(transferId, quotaId);
    }

    function approveTransfer(uint256 transferId) external {
        require(isFisheryManager[msg.sender], "Not manager");
        transfers[transferId].approved = true;
        emit TransferApproved(transferId);
    }
}
