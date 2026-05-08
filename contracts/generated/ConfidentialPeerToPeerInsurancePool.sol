// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialPeerToPeerInsurancePool
/// @notice Encrypted P2P insurance pool: private member risk scores, hidden
///         premium contributions, confidential claim adjudication, and
///         encrypted cashback distributions from unclaimed reserves.
contract ConfidentialPeerToPeerInsurancePool is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CoverageType { Health, Auto, Home, Travel, Pet, Business }
    enum ClaimStatus { Pending, Approved, Rejected, Paid }

    struct PoolMember {
        address member;
        CoverageType coverage;
        euint64 premiumPaidUSD;        // encrypted premium
        euint64 coverageLimitUSD;      // encrypted limit
        euint64 riskScore;             // encrypted risk
        euint64 claimsHistoryScore;    // encrypted claims history
        euint64 cashbackReceivedUSD;   // encrypted cashback
        uint256 joinedAt;
        uint256 policyExpiry;
        bool active;
    }

    struct InsuranceClaim {
        uint256 memberId;
        CoverageType coverage;
        euint64 claimAmountUSD;        // encrypted claim
        euint64 approvedAmountUSD;     // encrypted approved
        euint16 adjudicationScore;     // encrypted score
        ClaimStatus status;
        uint256 filedAt;
    }

    mapping(uint256 => PoolMember) private members;
    mapping(address => uint256) private memberIdByWallet;
    mapping(uint256 => InsuranceClaim) private claims;
    mapping(CoverageType => euint64) private poolReserves; // encrypted reserve per coverage

    uint256 public memberCount;
    uint256 public claimCount;
    euint64 private _totalPremiumsCollectedUSD;
    euint64 private _totalClaimsPaidUSD;
    euint64 private _totalCashbackPaidUSD;

    event MemberJoined(uint256 indexed id, CoverageType coverage);
    event ClaimFiled(uint256 indexed claimId, uint256 memberId);
    event ClaimProcessed(uint256 indexed claimId, ClaimStatus status);
    event CashbackDistributed(uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _totalPremiumsCollectedUSD = FHE.asEuint64(0);
        _totalClaimsPaidUSD = FHE.asEuint64(0);
        _totalCashbackPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsCollectedUSD);
        FHE.allowThis(_totalClaimsPaidUSD);
        FHE.allowThis(_totalCashbackPaidUSD);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function joinPool(
        CoverageType coverage,
        externalEuint64 encPremium,  bytes calldata pProof,
        externalEuint64 encLimit,    bytes calldata lProof,
        externalEuint64 encRisk,     bytes calldata rProof,
        uint256 termMonths
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint64 limit   = FHE.fromExternal(encLimit, lProof);
        euint64 risk    = FHE.fromExternal(encRisk, rProof);
        id = memberCount++;
        memberIdByWallet[msg.sender] = id;
        members[id] = PoolMember({
            member: msg.sender, coverage: coverage, premiumPaidUSD: premium,
            coverageLimitUSD: limit, riskScore: risk, claimsHistoryScore: FHE.asEuint64(5000),
            cashbackReceivedUSD: FHE.asEuint64(0), joinedAt: block.timestamp,
            policyExpiry: block.timestamp + termMonths * 30 days, active: true
        });
        if (!FHE.isInitialized(poolReserves[coverage])) { poolReserves[coverage] = FHE.asEuint64(0); FHE.allowThis(poolReserves[coverage]); }
        poolReserves[coverage] = FHE.add(poolReserves[coverage], premium);
        _totalPremiumsCollectedUSD = FHE.add(_totalPremiumsCollectedUSD, premium);
        FHE.allowThis(members[id].premiumPaidUSD); FHE.allow(members[id].premiumPaidUSD, msg.sender);
        FHE.allowThis(members[id].coverageLimitUSD); FHE.allow(members[id].coverageLimitUSD, msg.sender);
        FHE.allowThis(members[id].riskScore);
        FHE.allowThis(members[id].claimsHistoryScore); FHE.allow(members[id].claimsHistoryScore, msg.sender);
        FHE.allowThis(members[id].cashbackReceivedUSD); FHE.allow(members[id].cashbackReceivedUSD, msg.sender);
        FHE.allowThis(poolReserves[coverage]); FHE.allowThis(_totalPremiumsCollectedUSD);
        emit MemberJoined(id, coverage);
    }

    function fileClaim(uint256 memberId, externalEuint64 encClaim, bytes calldata proof) external whenNotPaused returns (uint256 claimId) {
        PoolMember storage m = members[memberId];
        require(m.member == msg.sender && m.active && block.timestamp < m.policyExpiry, "Invalid claim");
        euint64 claimAmt = FHE.fromExternal(encClaim, proof);
        ebool withinLimit = FHE.le(claimAmt, m.coverageLimitUSD);
        euint64 effClaim = FHE.select(withinLimit, claimAmt, m.coverageLimitUSD);
        claimId = claimCount++;
        claims[claimId] = InsuranceClaim({
            memberId: memberId, coverage: m.coverage, claimAmountUSD: effClaim,
            approvedAmountUSD: FHE.asEuint64(0), adjudicationScore: FHE.asEuint16(0),
            status: ClaimStatus.Pending, filedAt: block.timestamp
        });
        FHE.allowThis(claims[claimId].claimAmountUSD); FHE.allow(claims[claimId].claimAmountUSD, msg.sender);
        FHE.allowThis(claims[claimId].approvedAmountUSD); FHE.allow(claims[claimId].approvedAmountUSD, msg.sender);
        FHE.allowThis(claims[claimId].adjudicationScore);
        emit ClaimFiled(claimId, memberId);
    }

    function processClaim(uint256 claimId, bool approve, externalEuint64 encApprovedAmt, bytes calldata proof, externalEuint16 encScore, bytes calldata sProof) external onlyOwner nonReentrant {
        InsuranceClaim storage c = claims[claimId];
        require(c.status == ClaimStatus.Pending, "Already processed");
        euint64 approvedAmt = FHE.fromExternal(encApprovedAmt, proof);
        euint16 score = FHE.fromExternal(encScore, sProof);
        c.adjudicationScore = score;
        if (approve) {
            c.approvedAmountUSD = approvedAmt;
            c.status = ClaimStatus.Paid;
            poolReserves[c.coverage] = FHE.sub(poolReserves[c.coverage], approvedAmt);
            _totalClaimsPaidUSD = FHE.add(_totalClaimsPaidUSD, approvedAmt);
            FHE.allow(c.approvedAmountUSD, members[c.memberId].member);
            FHE.allowThis(poolReserves[c.coverage]); FHE.allowThis(_totalClaimsPaidUSD);
        } else {
            c.status = ClaimStatus.Rejected;
        }
        FHE.allowThis(c.adjudicationScore);
        emit ClaimProcessed(claimId, c.status);
    }

    function distributeCashback(uint256 memberId, externalEuint64 encCashback, bytes calldata proof) external onlyOwner {
        PoolMember storage m = members[memberId];
        euint64 cashback = FHE.fromExternal(encCashback, proof);
        m.cashbackReceivedUSD = FHE.add(m.cashbackReceivedUSD, cashback);
        _totalCashbackPaidUSD = FHE.add(_totalCashbackPaidUSD, cashback);
        FHE.allowThis(m.cashbackReceivedUSD); FHE.allow(m.cashbackReceivedUSD, m.member);
        FHE.allow(cashback, m.member);
        FHE.allowThis(_totalCashbackPaidUSD);
        emit CashbackDistributed(block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsCollectedUSD, viewer); FHE.allow(_totalClaimsPaidUSD, viewer); FHE.allow(_totalCashbackPaidUSD, viewer);
    }
}
