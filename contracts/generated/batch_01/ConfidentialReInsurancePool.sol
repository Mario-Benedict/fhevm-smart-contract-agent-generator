// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialReInsurancePool
/// @notice Reinsurance syndicate: cedants submit encrypted loss events;
///         pool members share encrypted loss portions based on their quota shares.
///         Treaty limits and retention levels remain confidential on-chain.
contract ConfidentialReInsurancePool is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum TreatyType { QuotaShare, ExcessOfLoss, StopLoss }
    enum ClaimStatus { Pending, Approved, Rejected, Paid }

    struct Treaty {
        address cedant;
        TreatyType treatyType;
        euint64 limitUSD;              // encrypted treaty limit
        euint64 retentionUSD;          // encrypted cedant retention
        euint64 premiumUSD;            // encrypted ceded premium
        euint64 totalCededLossUSD;     // encrypted cumulative ceded loss
        uint256 expiryDate;
        bool active;
    }

    struct LossClaim {
        uint256 treatyId;
        euint64 grossLossUSD;          // encrypted gross loss
        euint64 cededLossUSD;          // encrypted portion ceded to reinsurer
        euint64 retainedLossUSD;       // encrypted cedant retention
        ClaimStatus status;
        uint256 reportedAt;
    }

    struct PoolMember {
        euint32 quotaShareBps;         // encrypted quota share in basis points
        euint64 capitalContributed;    // encrypted capital contribution
        euint64 lossAbsorbed;          // encrypted cumulative loss absorbed
        bool active;
    }

    mapping(uint256 => Treaty) private treaties;
    mapping(uint256 => LossClaim) private claims;
    mapping(address => PoolMember) private members;
    mapping(address => bool) public isCedant;
    address[] public memberList;

    uint256 public treatyCount;
    uint256 public claimCount;
    euint64 private _totalPoolCapital;
    euint64 private _totalCededPremiums;

    event TreatyCreated(uint256 indexed id, address cedant);
    event ClaimSubmitted(uint256 indexed claimId, uint256 treatyId);
    event ClaimApproved(uint256 indexed claimId);
    event ClaimPaid(uint256 indexed claimId);

    modifier onlyCedant(uint256 treatyId) {
        require(treaties[treatyId].cedant == msg.sender, "Not cedant");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPoolCapital = FHE.asEuint64(0);
        _totalCededPremiums = FHE.asEuint64(0);
        FHE.allowThis(_totalPoolCapital);
        FHE.allowThis(_totalCededPremiums);
    }

    function addCedant(address c) external onlyOwner { isCedant[c] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function joinPool(
        externalEuint32 encQuota, bytes calldata qProof,
        externalEuint64 encCapital, bytes calldata cProof
    ) external whenNotPaused nonReentrant {
        euint32 quota = FHE.fromExternal(encQuota, qProof);
        euint64 capital = FHE.fromExternal(encCapital, cProof);
        members[msg.sender] = PoolMember({
            quotaShareBps: quota,
            capitalContributed: capital,
            lossAbsorbed: FHE.asEuint64(0),
            active: true
        });
        _totalPoolCapital = FHE.add(_totalPoolCapital, capital);
        FHE.allowThis(members[msg.sender].quotaShareBps);
        FHE.allow(members[msg.sender].quotaShareBps, msg.sender);
        FHE.allowThis(members[msg.sender].capitalContributed);
        FHE.allow(members[msg.sender].capitalContributed, msg.sender);
        FHE.allowThis(members[msg.sender].lossAbsorbed);
        FHE.allowThis(_totalPoolCapital);
        memberList.push(msg.sender);
    }

    function createTreaty(
        TreatyType tType,
        externalEuint64 encLimit, bytes calldata lProof,
        externalEuint64 encRetention, bytes calldata rProof,
        externalEuint64 encPremium, bytes calldata pProof,
        uint256 expiryDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isCedant[msg.sender], "Not cedant");
        euint64 limit = FHE.fromExternal(encLimit, lProof);
        euint64 retention = FHE.fromExternal(encRetention, rProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        id = treatyCount++;
        treaties[id] = Treaty({
            cedant: msg.sender,
            treatyType: tType,
            limitUSD: limit,
            retentionUSD: retention,
            premiumUSD: premium,
            totalCededLossUSD: FHE.asEuint64(0),
            expiryDate: block.timestamp + expiryDays * 1 days,
            active: true
        });
        _totalCededPremiums = FHE.add(_totalCededPremiums, premium);
        FHE.allowThis(treaties[id].limitUSD);
        FHE.allow(treaties[id].limitUSD, msg.sender);
        FHE.allowThis(treaties[id].retentionUSD);
        FHE.allow(treaties[id].retentionUSD, msg.sender);
        FHE.allowThis(treaties[id].premiumUSD);
        FHE.allowThis(treaties[id].totalCededLossUSD);
        FHE.allowThis(_totalCededPremiums);
        emit TreatyCreated(id, msg.sender);
    }

    function submitClaim(
        uint256 treatyId,
        externalEuint64 encGrossLoss, bytes calldata proof
    ) external onlyCedant(treatyId) nonReentrant returns (uint256 claimId) {
        Treaty storage t = treaties[treatyId];
        require(t.active && block.timestamp < t.expiryDate, "Treaty inactive");
        euint64 grossLoss = FHE.fromExternal(encGrossLoss, proof);
        // Ceded loss = max(0, grossLoss - retention), capped at limit
        ebool exceedsRetention = FHE.gt(grossLoss, t.retentionUSD);
        euint64 excessLoss = FHE.select(exceedsRetention,
            FHE.sub(grossLoss, t.retentionUSD), FHE.asEuint64(0));
        ebool withinLimit = FHE.le(excessLoss, t.limitUSD);
        euint64 cededLoss = FHE.select(withinLimit, excessLoss, t.limitUSD);
        euint64 retainedLoss = FHE.sub(grossLoss, cededLoss);
        claimId = claimCount++;
        claims[claimId] = LossClaim({
            treatyId: treatyId,
            grossLossUSD: grossLoss,
            cededLossUSD: cededLoss,
            retainedLossUSD: retainedLoss,
            status: ClaimStatus.Pending,
            reportedAt: block.timestamp
        });
        t.totalCededLossUSD = FHE.add(t.totalCededLossUSD, cededLoss);
        FHE.allowThis(claims[claimId].grossLossUSD);
        FHE.allow(claims[claimId].grossLossUSD, msg.sender);
        FHE.allowThis(claims[claimId].cededLossUSD);
        FHE.allow(claims[claimId].cededLossUSD, msg.sender);
        FHE.allowThis(claims[claimId].retainedLossUSD);
        FHE.allow(claims[claimId].retainedLossUSD, msg.sender);
        FHE.allowThis(t.totalCededLossUSD);
        emit ClaimSubmitted(claimId, treatyId);
    }

    function approveClaim(uint256 claimId) external onlyOwner {
        claims[claimId].status = ClaimStatus.Approved;
        emit ClaimApproved(claimId);
    }

    function payClaim(uint256 claimId) external onlyOwner nonReentrant {
        LossClaim storage c = claims[claimId];
        require(c.status == ClaimStatus.Approved, "Not approved");
        c.status = ClaimStatus.Paid;
        emit ClaimPaid(claimId);
    }

    function allowMemberStats(address viewer) external {
        require(members[msg.sender].active, "Not member");
        FHE.allow(members[msg.sender].quotaShareBps, viewer);
        FHE.allow(members[msg.sender].capitalContributed, viewer);
        FHE.allow(members[msg.sender].lossAbsorbed, viewer);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPoolCapital, viewer);
        FHE.allow(_totalCededPremiums, viewer);
    }
}
