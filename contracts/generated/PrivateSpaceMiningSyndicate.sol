// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSpaceMiningSyndicate
/// @notice Encrypted asteroid mining rights syndicate: encrypted ore grades, hidden extraction
///         quotas, private profit-sharing among consortium members, and confidential royalty to
///         space agency. Branchless FHE select for conditional payouts.
contract PrivateSpaceMiningSyndicate is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum OreType { Platinum, Palladium, Gold, Nickel, Iron, Helium3 }
    enum MissionStatus { Planning, Transit, Extraction, ReturnTrip, Settled, Aborted }

    struct MiningClaim {
        address claimHolder;
        string asteroidId;
        OreType oreType;
        euint32 estimatedTonnes;      // encrypted ore estimate
        euint64 extractionCostUSD;    // encrypted cost of extraction mission
        euint64 marketValueUSD;       // encrypted current market value
        euint64 netRevenueUSD;        // encrypted net revenue post royalty
        uint256 missionLaunch;
        MissionStatus status;
    }

    struct SyndicateMember {
        address member;
        euint16 sharesBps;            // encrypted ownership % in bps
        euint64 accruedPayoutUSD;     // encrypted accumulated payout
        bool active;
    }

    uint32 public constant ROYALTY_BPS = 800; // 8% government royalty, plaintext

    mapping(uint256 => MiningClaim) private claims;
    mapping(uint256 => SyndicateMember) private members;
    mapping(address => uint256) public memberIndex;
    mapping(address => bool) public isMember;
    mapping(address => bool) public isSpaceAuthority;

    uint256 public claimCount;
    uint256 public memberCount;
    euint64 private _syndicateTreasuryUSD;
    euint64 private _totalRoyaltiesPaidUSD;
    euint64 private _totalExtractedValueUSD;

    event ClaimRegistered(uint256 indexed id, string asteroidId, OreType oreType);
    event MemberAdded(uint256 indexed idx, address member);
    event MissionUpdated(uint256 indexed id, MissionStatus status);
    event ExtractionFinalized(uint256 indexed claimId);

    modifier onlyAuthority() {
        require(isSpaceAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    modifier onlyMember() {
        require(isMember[msg.sender], "Not syndicate member");
        _;
    }

    constructor() Ownable(msg.sender) {
        _syndicateTreasuryUSD = FHE.asEuint64(0);
        _totalRoyaltiesPaidUSD = FHE.asEuint64(0);
        _totalExtractedValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_syndicateTreasuryUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        FHE.allowThis(_totalExtractedValueUSD);
        isSpaceAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addSpaceAuthority(address a) external onlyOwner { isSpaceAuthority[a] = true; }

    function addMember(
        address member,
        externalEuint16 encShares, bytes calldata sProof
    ) external onlyOwner {
        require(!isMember[member], "Already member");
        euint16 shares = FHE.fromExternal(encShares, sProof);
        uint256 idx = memberCount++;
        members[idx] = SyndicateMember({
            member: member,
            sharesBps: shares,
            accruedPayoutUSD: FHE.asEuint64(0),
            active: true
        });
        memberIndex[member] = idx;
        isMember[member] = true;
        FHE.allowThis(members[idx].sharesBps);
        FHE.allow(members[idx].sharesBps, member);
        FHE.allowThis(members[idx].accruedPayoutUSD);
        FHE.allow(members[idx].accruedPayoutUSD, member);
        emit MemberAdded(idx, member);
    }

    function registerClaim(
        string calldata asteroidId,
        OreType oreType,
        externalEuint32 encTonnes, bytes calldata tProof,
        externalEuint64 encCost, bytes calldata cProof,
        externalEuint64 encValue, bytes calldata vProof
    ) external onlyMember whenNotPaused returns (uint256 id) {
        euint32 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 cost = FHE.fromExternal(encCost, cProof);
        euint64 mktValue = FHE.fromExternal(encValue, vProof);
        id = claimCount++;
        claims[id] = MiningClaim({
            claimHolder: msg.sender,
            asteroidId: asteroidId,
            oreType: oreType,
            estimatedTonnes: tonnes,
            extractionCostUSD: cost,
            marketValueUSD: mktValue,
            netRevenueUSD: FHE.asEuint64(0),
            missionLaunch: block.timestamp,
            status: MissionStatus.Planning
        });
        FHE.allowThis(claims[id].estimatedTonnes); FHE.allow(claims[id].estimatedTonnes, msg.sender);
        FHE.allowThis(claims[id].extractionCostUSD); FHE.allow(claims[id].extractionCostUSD, msg.sender);
        FHE.allowThis(claims[id].marketValueUSD); FHE.allow(claims[id].marketValueUSD, msg.sender);
        FHE.allowThis(claims[id].netRevenueUSD);
        emit ClaimRegistered(id, asteroidId, oreType);
    }

    function setMissionStatus(uint256 claimId, MissionStatus newStatus) external onlyAuthority {
        claims[claimId].status = newStatus;
        emit MissionUpdated(claimId, newStatus);
    }

    /// @notice Finalize extraction with actual revenue; royalty is a plaintext 8% constant
    function finalizeExtraction(
        uint256 claimId,
        externalEuint64 encActualRevenue, bytes calldata proof
    ) external onlyAuthority nonReentrant {
        MiningClaim storage c = claims[claimId];
        require(c.status == MissionStatus.ReturnTrip, "Not in return trip");
        euint64 actualRevenue = FHE.fromExternal(encActualRevenue, proof);
        // Royalty = revenue * ROYALTY_BPS / 10000 — plaintext divisors
        euint64 royaltyAmt = FHE.div(FHE.mul(actualRevenue, FHE.asEuint64(uint64(ROYALTY_BPS))), 10000);
        euint64 netRev = FHE.sub(actualRevenue, royaltyAmt);
        c.netRevenueUSD = netRev;
        c.status = MissionStatus.Settled;
        _syndicateTreasuryUSD = FHE.add(_syndicateTreasuryUSD, netRev);
        _totalRoyaltiesPaidUSD = FHE.add(_totalRoyaltiesPaidUSD, royaltyAmt);
        _totalExtractedValueUSD = FHE.add(_totalExtractedValueUSD, actualRevenue);
        FHE.allowThis(c.netRevenueUSD);
        FHE.allow(c.netRevenueUSD, c.claimHolder);
        FHE.allowThis(_syndicateTreasuryUSD);
        FHE.allowThis(_totalRoyaltiesPaidUSD);
        FHE.allowThis(_totalExtractedValueUSD);
        emit ExtractionFinalized(claimId);
    }

    /// @notice Distribute payout to a single member based on their encrypted share (plaintext bps provided)
    function distributeMemberPayout(
        uint256 memberId,
        externalEuint64 encPayout, bytes calldata proof
    ) external onlyOwner nonReentrant {
        SyndicateMember storage m = members[memberId];
        require(m.active, "Inactive member");
        euint64 payout = FHE.fromExternal(encPayout, proof);
        m.accruedPayoutUSD = FHE.add(m.accruedPayoutUSD, payout);
        _syndicateTreasuryUSD = FHE.sub(_syndicateTreasuryUSD, payout);
        FHE.allowThis(m.accruedPayoutUSD); FHE.allow(m.accruedPayoutUSD, m.member);
        FHE.allowThis(_syndicateTreasuryUSD);
    }

    function allowTreasuryView(address viewer) external onlyOwner {
        FHE.allow(_syndicateTreasuryUSD, viewer);
        FHE.allow(_totalRoyaltiesPaidUSD, viewer);
        FHE.allow(_totalExtractedValueUSD, viewer);
    }
}
