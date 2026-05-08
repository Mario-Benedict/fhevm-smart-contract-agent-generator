// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDisasterReliefFundManager
/// @notice Encrypted disaster relief fund: hidden damage assessments, private
///         beneficiary need scores, confidential fund allocation decisions,
///         and encrypted aid disbursement tracking with donor anonymity.
contract PrivateDisasterReliefFundManager is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DisasterType { Earthquake, Flood, Wildfire, Hurricane, Drought, Pandemic, Industrial }
    enum BeneficiaryCategory { Individual, Household, Community, SmallBusiness, Infrastructure }

    struct DisasterEvent {
        string eventRef;
        string location;
        DisasterType disasterType;
        euint64 estimatedDamageUSD;    // encrypted damage
        euint64 fundsAllocatedUSD;     // encrypted allocation
        euint64 fundsDistributedUSD;   // encrypted distributed
        euint32 beneficiaryCount;      // encrypted count
        uint256 declaredAt;
        bool active;
    }

    struct BeneficiaryRecord {
        address beneficiary;
        uint256 eventId;
        BeneficiaryCategory category;
        euint64 needAssessmentUSD;     // encrypted need score
        euint64 aidReceivedUSD;        // encrypted aid received
        euint16 vulnerabilityScore;    // encrypted vulnerability
        bool approved;
    }

    struct DonationRecord {
        address donor;
        euint64 amountUSD;             // encrypted donation
        uint256 eventId;
        uint256 donatedAt;
    }

    mapping(uint256 => DisasterEvent) private events;
    mapping(uint256 => BeneficiaryRecord) private beneficiaries;
    mapping(uint256 => DonationRecord) private donations;
    mapping(address => bool) public isReliefCoordinator;

    uint256 public eventCount;
    uint256 public beneficiaryCount;
    uint256 public donationCount;
    euint64 private _totalDonationsUSD;
    euint64 private _totalAidDistributedUSD;

    event DisasterDeclared(uint256 indexed id, DisasterType disasterType);
    event BeneficiaryRegistered(uint256 indexed id, uint256 eventId);
    event AidDisbursed(uint256 indexed beneficiaryId, uint256 disbursedAt);
    event DonationReceived(uint256 indexed donationId, uint256 eventId);

    modifier onlyReliefCoordinator() {
        require(isReliefCoordinator[msg.sender] || msg.sender == owner(), "Not relief coordinator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDonationsUSD = FHE.asEuint64(0);
        _totalAidDistributedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalDonationsUSD);
        FHE.allowThis(_totalAidDistributedUSD);
        isReliefCoordinator[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addReliefCoordinator(address rc) external onlyOwner { isReliefCoordinator[rc] = true; }

    function declareDisaster(
        string calldata eventRef, string calldata location, DisasterType disasterType,
        externalEuint64 encDamage, bytes calldata dProof,
        externalEuint64 encAllocation, bytes calldata alProof
    ) external onlyReliefCoordinator returns (uint256 id) {
        euint64 damage     = FHE.fromExternal(encDamage, dProof);
        euint64 allocation = FHE.fromExternal(encAllocation, alProof);
        id = eventCount++;
        events[id] = DisasterEvent({
            eventRef: eventRef, location: location, disasterType: disasterType,
            estimatedDamageUSD: damage, fundsAllocatedUSD: allocation,
            fundsDistributedUSD: FHE.asEuint64(0), beneficiaryCount: FHE.asEuint32(0),
            declaredAt: block.timestamp, active: true
        });
        FHE.allowThis(events[id].estimatedDamageUSD); FHE.allow(events[id].estimatedDamageUSD, msg.sender);
        FHE.allowThis(events[id].fundsAllocatedUSD); FHE.allow(events[id].fundsAllocatedUSD, msg.sender);
        FHE.allowThis(events[id].fundsDistributedUSD); FHE.allow(events[id].fundsDistributedUSD, msg.sender);
        FHE.allowThis(events[id].beneficiaryCount);
        emit DisasterDeclared(id, disasterType);
    }

    function registerBeneficiary(
        uint256 eventId, address beneficiary, BeneficiaryCategory category,
        externalEuint64 encNeed, bytes calldata nProof,
        externalEuint16 encVulnerability, bytes calldata vProof
    ) external onlyReliefCoordinator returns (uint256 id) {
        euint64 need         = FHE.fromExternal(encNeed, nProof);
        euint16 vulnerability= FHE.fromExternal(encVulnerability, vProof);
        id = beneficiaryCount++;
        beneficiaries[id] = BeneficiaryRecord({
            beneficiary: beneficiary, eventId: eventId, category: category,
            needAssessmentUSD: need, aidReceivedUSD: FHE.asEuint64(0),
            vulnerabilityScore: vulnerability, approved: true
        });
        events[eventId].beneficiaryCount = FHE.add(events[eventId].beneficiaryCount, FHE.asEuint32(1));
        FHE.allowThis(beneficiaries[id].needAssessmentUSD);
        FHE.allowThis(beneficiaries[id].aidReceivedUSD); FHE.allow(beneficiaries[id].aidReceivedUSD, beneficiary);
        FHE.allowThis(beneficiaries[id].vulnerabilityScore);
        FHE.allowThis(events[eventId].beneficiaryCount);
        emit BeneficiaryRegistered(id, eventId);
    }

    function disburseAid(uint256 beneficiaryId, externalEuint64 encAid, bytes calldata proof) external onlyReliefCoordinator nonReentrant {
        BeneficiaryRecord storage b = beneficiaries[beneficiaryId];
        require(b.approved, "Not approved");
        euint64 aid = FHE.fromExternal(encAid, proof);
        DisasterEvent storage ev = events[b.eventId];
        ebool fundsAvailable = FHE.ge(FHE.sub(ev.fundsAllocatedUSD, ev.fundsDistributedUSD), aid);
        euint64 effAid = FHE.select(fundsAvailable, aid, FHE.sub(ev.fundsAllocatedUSD, ev.fundsDistributedUSD));
        b.aidReceivedUSD = FHE.add(b.aidReceivedUSD, effAid);
        ev.fundsDistributedUSD = FHE.add(ev.fundsDistributedUSD, effAid);
        _totalAidDistributedUSD = FHE.add(_totalAidDistributedUSD, effAid);
        FHE.allowThis(b.aidReceivedUSD); FHE.allow(b.aidReceivedUSD, b.beneficiary);
        FHE.allow(effAid, b.beneficiary);
        FHE.allowThis(ev.fundsDistributedUSD); FHE.allow(ev.fundsDistributedUSD, msg.sender);
        FHE.allowThis(_totalAidDistributedUSD);
        emit AidDisbursed(beneficiaryId, block.timestamp);
    }

    function donate(uint256 eventId, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused nonReentrant returns (uint256 donationId) {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        events[eventId].fundsAllocatedUSD = FHE.add(events[eventId].fundsAllocatedUSD, amt);
        _totalDonationsUSD = FHE.add(_totalDonationsUSD, amt);
        donationId = donationCount++;
        donations[donationId] = DonationRecord({ donor: msg.sender, amountUSD: amt, eventId: eventId, donatedAt: block.timestamp });
        FHE.allowThis(events[eventId].fundsAllocatedUSD);
        FHE.allowThis(donations[donationId].amountUSD); FHE.allow(donations[donationId].amountUSD, msg.sender);
        FHE.allowThis(_totalDonationsUSD);
        emit DonationReceived(donationId, eventId);
    }

    function allowReliefStats(address viewer) external onlyOwner {
        FHE.allow(_totalDonationsUSD, viewer); FHE.allow(_totalAidDistributedUSD, viewer);
    }
}
