// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateWaterRightsTokenRegistry
/// @notice Encrypted water rights tokenization: hidden allocation volumes,
///         private transferable entitlements, confidential usage metering,
///         and encrypted drought-triggered curtailment logic.
contract PrivateWaterRightsTokenRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WaterRightType { Surface, Groundwater, Recycled, StormwaterHarvesting }
    enum SeniorityClass { Senior, Junior, Conditional, Temporary }

    struct WaterRight {
        address holder;
        WaterRightType rightType;
        SeniorityClass seniority;
        string rightRef;
        string waterBody;
        euint64 allocatedAcreFeet;     // encrypted allocation
        euint64 usedAcreFeet;          // encrypted usage
        euint64 transferableAcreFeet;  // encrypted transferable portion
        euint64 marketValueUSD;        // encrypted market value
        euint16 droughtCurtailmentBps; // encrypted curtailment %
        uint256 expiryDate;
        bool active;
    }

    struct WaterUsageLog {
        uint256 rightId;
        address user;
        euint64 volumeAcreFeet;        // encrypted usage volume
        euint64 qualityScore;          // encrypted water quality
        uint256 loggedAt;
    }

    mapping(uint256 => WaterRight) private waterRights;
    mapping(uint256 => WaterUsageLog) private usageLogs;
    mapping(address => bool) public isWaterAuthority;

    uint256 public rightCount;
    uint256 public usageLogCount;
    euint64 private _totalAllocatedAcreFeet;
    euint64 private _totalUsedAcreFeet;
    euint64 private _totalMarketValueUSD;

    event WaterRightIssued(uint256 indexed id, WaterRightType rightType, SeniorityClass seniority);
    event UsageLogged(uint256 indexed logId, uint256 rightId);
    event DroughtCurtailmentApplied(uint256 indexed rightId);
    event WaterRightTransferred(uint256 indexed rightId, address newHolder);

    modifier onlyWaterAuthority() {
        require(isWaterAuthority[msg.sender] || msg.sender == owner(), "Not water authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAllocatedAcreFeet = FHE.asEuint64(0);
        _totalUsedAcreFeet = FHE.asEuint64(0);
        _totalMarketValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAllocatedAcreFeet);
        FHE.allowThis(_totalUsedAcreFeet);
        FHE.allowThis(_totalMarketValueUSD);
        isWaterAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addWaterAuthority(address wa) external onlyOwner { isWaterAuthority[wa] = true; }

    function issueWaterRight(
        address holder, WaterRightType rightType, SeniorityClass seniority,
        string calldata rightRef, string calldata waterBody,
        externalEuint64 encAllocation,   bytes calldata alProof,
        externalEuint64 encTransferable, bytes calldata trProof,
        externalEuint64 encMarketValue,  bytes calldata mvProof,
        uint256 expiryYears
    ) external onlyWaterAuthority whenNotPaused returns (uint256 id) {
        euint64 allocation   = FHE.fromExternal(encAllocation, alProof);
        euint64 transferable = FHE.fromExternal(encTransferable, trProof);
        euint64 marketValue  = FHE.fromExternal(encMarketValue, mvProof);
        id = rightCount++;
        waterRights[id] = WaterRight({
            holder: holder, rightType: rightType, seniority: seniority, rightRef: rightRef,
            waterBody: waterBody, allocatedAcreFeet: allocation, usedAcreFeet: FHE.asEuint64(0),
            transferableAcreFeet: transferable, marketValueUSD: marketValue,
            droughtCurtailmentBps: FHE.asEuint16(0), expiryDate: block.timestamp + expiryYears * 365 days, active: true
        });
        _totalAllocatedAcreFeet = FHE.add(_totalAllocatedAcreFeet, allocation);
        _totalMarketValueUSD = FHE.add(_totalMarketValueUSD, marketValue);
        FHE.allowThis(waterRights[id].allocatedAcreFeet); FHE.allow(waterRights[id].allocatedAcreFeet, holder);
        FHE.allowThis(waterRights[id].usedAcreFeet); FHE.allow(waterRights[id].usedAcreFeet, holder);
        FHE.allowThis(waterRights[id].transferableAcreFeet); FHE.allow(waterRights[id].transferableAcreFeet, holder);
        FHE.allowThis(waterRights[id].marketValueUSD); FHE.allow(waterRights[id].marketValueUSD, holder);
        FHE.allowThis(waterRights[id].droughtCurtailmentBps);
        FHE.allowThis(_totalAllocatedAcreFeet); FHE.allowThis(_totalMarketValueUSD);
        emit WaterRightIssued(id, rightType, seniority);
    }

    function logUsage(uint256 rightId, externalEuint64 encVolume, bytes calldata vProof, externalEuint64 encQuality, bytes calldata qProof) external whenNotPaused returns (uint256 logId) {
        WaterRight storage wr = waterRights[rightId];
        require(wr.holder == msg.sender && wr.active, "Not holder or inactive");
        euint64 volume  = FHE.fromExternal(encVolume, vProof);
        euint64 quality = FHE.fromExternal(encQuality, qProof);
        ebool withinAllocation = FHE.le(FHE.add(wr.usedAcreFeet, volume), wr.allocatedAcreFeet);
        euint64 effVolume = FHE.select(withinAllocation, volume, FHE.sub(wr.allocatedAcreFeet, wr.usedAcreFeet));
        wr.usedAcreFeet = FHE.add(wr.usedAcreFeet, effVolume);
        _totalUsedAcreFeet = FHE.add(_totalUsedAcreFeet, effVolume);
        logId = usageLogCount++;
        usageLogs[logId] = WaterUsageLog({ rightId: rightId, user: msg.sender, volumeAcreFeet: effVolume, qualityScore: quality, loggedAt: block.timestamp });
        FHE.allowThis(wr.usedAcreFeet); FHE.allow(wr.usedAcreFeet, msg.sender);
        FHE.allowThis(usageLogs[logId].volumeAcreFeet); FHE.allow(usageLogs[logId].volumeAcreFeet, msg.sender);
        FHE.allowThis(usageLogs[logId].qualityScore); FHE.allow(usageLogs[logId].qualityScore, msg.sender);
        FHE.allowThis(_totalUsedAcreFeet);
        emit UsageLogged(logId, rightId);
    }

    function applyDroughtCurtailment(uint256 rightId, externalEuint16 encCurtailment, bytes calldata proof) external onlyWaterAuthority {
        euint16 curtailment = FHE.fromExternal(encCurtailment, proof);
        waterRights[rightId].droughtCurtailmentBps = curtailment;
        euint64 curtailedAlloc = FHE.sub(waterRights[rightId].allocatedAcreFeet, FHE.div(FHE.mul(waterRights[rightId].allocatedAcreFeet, 1000), 10000));
        waterRights[rightId].allocatedAcreFeet = curtailedAlloc;
        FHE.allowThis(waterRights[rightId].droughtCurtailmentBps);
        FHE.allowThis(waterRights[rightId].allocatedAcreFeet); FHE.allow(waterRights[rightId].allocatedAcreFeet, waterRights[rightId].holder);
        emit DroughtCurtailmentApplied(rightId);
    }

    function transferWaterRight(uint256 rightId, address newHolder) external nonReentrant {
        WaterRight storage wr = waterRights[rightId];
        require(wr.holder == msg.sender && wr.active, "Not holder");
        wr.holder = newHolder;
        FHE.allow(wr.allocatedAcreFeet, newHolder); FHE.allow(wr.transferableAcreFeet, newHolder);
        FHE.allow(wr.marketValueUSD, newHolder); FHE.allow(wr.usedAcreFeet, newHolder);
        emit WaterRightTransferred(rightId, newHolder);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalAllocatedAcreFeet, viewer); FHE.allow(_totalUsedAcreFeet, viewer); FHE.allow(_totalMarketValueUSD, viewer);
    }
}
