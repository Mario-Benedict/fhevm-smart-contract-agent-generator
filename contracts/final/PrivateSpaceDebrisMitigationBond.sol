// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSpaceDebrisMitigationBond
/// @notice Space agency liability bond system where satellite operators
///         post encrypted performance bonds, debris removal bids are sealed,
///         and collision risk scores are kept confidential.
contract PrivateSpaceDebrisMitigationBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OrbitRegime { LEO, MEO, GEO, HEO, SSO, POLAR }
    enum DebrisClass { FUNCTIONAL_SATELLITE, SPENT_ROCKET_BODY, FRAGMENTATION, MICROPARTICLE }

    struct SatelliteRegistration {
        string satelliteName;
        string noradId;
        address operator;
        OrbitRegime orbit;
        euint64 performanceBondUSD;    // encrypted bond posted
        euint32 collisionProbability;  // encrypted Pc (scaled 1e6)
        euint32 debrisObjectsCreated;  // encrypted tracked fragments
        euint8  complianceScore;       // encrypted ITU compliance 0-100
        euint64 operationalLifeYears;  // encrypted mission design life
        uint256 launchDate;
        bool deorbited;
        bool bondForfeited;
    }

    struct DebrisRemovalBid {
        uint256 debrisObjectId;
        address removalCompany;
        euint64 bidAmountUSD;          // encrypted sealed bid
        euint64 proposedCostUSD;       // encrypted cost estimate
        euint32 removalTimelineDays;   // encrypted
        euint8  technicalFeasibility;  // encrypted 0-100
        uint256 bidTimestamp;
        bool awarded;
        bool completed;
    }

    struct RemovalCompanyProfile {
        euint64 totalContractValue;    // encrypted total contracts won
        euint8  successRate;           // encrypted mission success %
        euint32 missionsCompleted;     // encrypted count
        bool certified;
    }

    mapping(uint256 => SatelliteRegistration) private satellites;
    mapping(uint256 => DebrisRemovalBid) private bids;
    mapping(address => RemovalCompanyProfile) private companies;
    mapping(address => bool) public isSpaceAgency;
    mapping(uint256 => uint256[]) private debrisBids; // debris object => bid IDs
    uint256 public satelliteCount;
    uint256 public bidCount;
    euint64 private _totalBondPoolUSD;
    euint64 private _totalRemovalContractsAwarded;

    event SatelliteRegistered(uint256 indexed satId, string noradId, OrbitRegime orbit);
    event BidSubmitted(uint256 indexed bidId, uint256 debrisObjectId);
    event BidAwarded(uint256 indexed bidId, address company);
    event RemovalCompleted(uint256 indexed bidId);
    event BondForfeited(uint256 indexed satId);

    constructor() Ownable(msg.sender) {
        _totalBondPoolUSD = FHE.asEuint64(0);
        _totalRemovalContractsAwarded = FHE.asEuint64(0);
        FHE.allowThis(_totalBondPoolUSD);
        FHE.allowThis(_totalRemovalContractsAwarded);
        isSpaceAgency[msg.sender] = true;
    }

    function addSpaceAgency(address agency) external onlyOwner { isSpaceAgency[agency] = true; }

    function certifyCompany(address company) external {
        require(isSpaceAgency[msg.sender], "Not agency");
        companies[company].certified = true;
        if (!FHE.isInitialized(companies[company].totalContractValue)) {
            companies[company].totalContractValue = FHE.asEuint64(0);
            companies[company].successRate = FHE.asEuint8(100);
            companies[company].missionsCompleted = FHE.asEuint32(0);
            FHE.allowThis(companies[company].totalContractValue);
            FHE.allowThis(companies[company].successRate);
            FHE.allowThis(companies[company].missionsCompleted);
        }
    }

    function registerSatellite(
        string calldata name,
        string calldata noradId,
        OrbitRegime orbit,
        externalEuint64 encBond,        bytes calldata bondProof,
        externalEuint32 encCollProb,    bytes calldata cpProof,
        externalEuint8  encCompliance,  bytes calldata compProof,
        externalEuint64 encLifeYears,   bytes calldata lyProof,
        uint256 launchDate
    ) external returns (uint256 satId) {
        euint64 bond     = FHE.fromExternal(encBond, bondProof);
        euint32 collProb = FHE.fromExternal(encCollProb, cpProof);
        euint8  comp     = FHE.fromExternal(encCompliance, compProof);
        euint64 lifeYrs  = FHE.fromExternal(encLifeYears, lyProof);
        satId = satelliteCount++;
        SatelliteRegistration storage _s0 = satellites[satId];
        _s0.satelliteName = name;
        _s0.noradId = noradId;
        _s0.operator = msg.sender;
        _s0.orbit = orbit;
        _s0.performanceBondUSD = bond;
        _s0.collisionProbability = collProb;
        _s0.debrisObjectsCreated = FHE.asEuint32(0);
        _s0.complianceScore = comp;
        _s0.operationalLifeYears = lifeYrs;
        _s0.launchDate = launchDate;
        _s0.deorbited = false;
        _s0.bondForfeited = false;
        _totalBondPoolUSD = FHE.add(_totalBondPoolUSD, bond);
        FHE.allowThis(satellites[satId].performanceBondUSD);
        FHE.allow(satellites[satId].performanceBondUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalBondPoolUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRemovalContractsAwarded, msg.sender); // [acl_misconfig]
        FHE.allowThis(satellites[satId].collisionProbability);
        FHE.allowThis(satellites[satId].debrisObjectsCreated);
        FHE.allowThis(satellites[satId].complianceScore);
        FHE.allow(satellites[satId].complianceScore, msg.sender);
        FHE.allowThis(satellites[satId].operationalLifeYears);
        FHE.allowThis(_totalBondPoolUSD);
        emit SatelliteRegistered(satId, noradId, orbit);
    }

    function submitRemovalBid(
        uint256 debrisObjectId,
        externalEuint64 encBid,         bytes calldata bidProof,
        externalEuint64 encCost,        bytes calldata costProof,
        externalEuint32 encTimeline,    bytes calldata tlProof,
        externalEuint8  encFeasibility, bytes calldata feasProof
    ) external returns (uint256 bidId) {
        require(companies[msg.sender].certified, "Not certified");
        euint64 bidAmt  = FHE.fromExternal(encBid, bidProof);
        euint64 cost    = FHE.fromExternal(encCost, costProof);
        euint32 timeline= FHE.fromExternal(encTimeline, tlProof);
        euint8  feasib  = FHE.fromExternal(encFeasibility, feasProof);
        bidId = bidCount++;
        bids[bidId].debrisObjectId = debrisObjectId;
        bids[bidId].removalCompany = msg.sender;
        bids[bidId].bidAmountUSD = bidAmt;
        bids[bidId].proposedCostUSD = cost;
        bids[bidId].removalTimelineDays = timeline;
        bids[bidId].technicalFeasibility = feasib;
        bids[bidId].bidTimestamp = block.timestamp;
        bids[bidId].awarded = false;
        bids[bidId].completed = false;
        debrisBids[debrisObjectId].push(bidId);
        FHE.allowThis(bids[bidId].bidAmountUSD);
        FHE.allow(bids[bidId].bidAmountUSD, msg.sender);
        FHE.allowThis(bids[bidId].proposedCostUSD);
        FHE.allowThis(bids[bidId].removalTimelineDays);
        FHE.allowThis(bids[bidId].technicalFeasibility);
        emit BidSubmitted(bidId, debrisObjectId);
    }

    function awardContract(uint256 bidId) external {
        require(isSpaceAgency[msg.sender], "Not agency");
        require(!bids[bidId].awarded, "Already awarded");
        bids[bidId].awarded = true;
        companies[bids[bidId].removalCompany].totalContractValue = FHE.add(
            companies[bids[bidId].removalCompany].totalContractValue,
            bids[bidId].bidAmountUSD
        );
        _totalRemovalContractsAwarded = FHE.add(_totalRemovalContractsAwarded, bids[bidId].bidAmountUSD);
        FHE.allowThis(companies[bids[bidId].removalCompany].totalContractValue);
        FHE.allowThis(_totalRemovalContractsAwarded);
        emit BidAwarded(bidId, bids[bidId].removalCompany);
    }

    function confirmRemovalCompleted(uint256 bidId) external {
        require(isSpaceAgency[msg.sender], "Not agency");
        require(bids[bidId].awarded && !bids[bidId].completed, "Invalid state");
        bids[bidId].completed = true;
        companies[bids[bidId].removalCompany].missionsCompleted = FHE.add(
            companies[bids[bidId].removalCompany].missionsCompleted, FHE.asEuint32(1)
        );
        FHE.allowThis(companies[bids[bidId].removalCompany].missionsCompleted);
        emit RemovalCompleted(bidId);
    }

    function forfeitBond(uint256 satId) external {
        require(isSpaceAgency[msg.sender], "Not agency");
        require(!satellites[satId].bondForfeited, "Already forfeited");
        satellites[satId].bondForfeited = true;
        emit BondForfeited(satId);
    }

    function allowPoolView(address viewer) external onlyOwner {
        FHE.allow(_totalBondPoolUSD, viewer);
        FHE.allow(_totalRemovalContractsAwarded, viewer);
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