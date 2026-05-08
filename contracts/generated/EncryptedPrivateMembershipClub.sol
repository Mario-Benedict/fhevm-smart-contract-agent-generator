// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateMembershipClub
/// @notice Encrypted exclusive membership club: private membership tier levels,
///         hidden subscription fees, confidential access privileges, and
///         encrypted points/rewards accumulation.
contract EncryptedPrivateMembershipClub is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MembershipTier { Bronze, Silver, Gold, Platinum, Diamond, Founding }

    struct Member {
        address wallet;
        MembershipTier tier;
        euint64 subscriptionFeeUSD;    // encrypted fee paid
        euint64 rewardPoints;          // encrypted points balance
        euint64 lifetimeSpendUSD;      // encrypted total spend
        euint16 accessPrivilegeBitfield; // encrypted privilege flags
        uint256 memberSince;
        uint256 subscriptionExpiry;
        bool active;
    }

    struct RewardEvent {
        address member;
        euint64 pointsEarned;          // encrypted points earned
        string  eventType;
        uint256 earnedAt;
    }

    mapping(uint256 => Member) private members;
    mapping(address => uint256) private memberIdByWallet;
    mapping(uint256 => RewardEvent) private rewardEvents;
    mapping(address => bool) public isClubManager;

    uint256 public memberCount;
    uint256 public rewardEventCount;
    euint64 private _totalRevenueUSD;
    euint64 private _totalPointsIssued;

    event MemberJoined(uint256 indexed id, MembershipTier tier);
    event MemberUpgraded(uint256 indexed id, MembershipTier newTier);
    event PointsEarned(uint256 indexed eventId, address member);
    event PointsRedeemed(address indexed member, uint256 redeemedAt);

    modifier onlyClubManager() {
        require(isClubManager[msg.sender] || msg.sender == owner(), "Not club manager");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRevenueUSD = FHE.asEuint64(0);
        _totalPointsIssued = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenueUSD);
        FHE.allowThis(_totalPointsIssued);
        isClubManager[msg.sender] = true;
    }

    function addClubManager(address cm) external onlyOwner { isClubManager[cm] = true; }

    function joinClub(
        address wallet, MembershipTier tier,
        externalEuint64 encFee, bytes calldata fProof,
        externalEuint16 encPrivileges, bytes calldata pProof,
        uint256 subscriptionMonths
    ) external onlyClubManager returns (uint256 id) {
        euint64 fee        = FHE.fromExternal(encFee, fProof);
        euint16 privileges = FHE.fromExternal(encPrivileges, pProof);
        id = memberCount++;
        memberIdByWallet[wallet] = id;
        members[id] = Member({
            wallet: wallet, tier: tier, subscriptionFeeUSD: fee,
            rewardPoints: FHE.asEuint64(0), lifetimeSpendUSD: fee,
            accessPrivilegeBitfield: privileges, memberSince: block.timestamp,
            subscriptionExpiry: block.timestamp + subscriptionMonths * 30 days, active: true
        });
        _totalRevenueUSD = FHE.add(_totalRevenueUSD, fee);
        FHE.allowThis(members[id].subscriptionFeeUSD); FHE.allow(members[id].subscriptionFeeUSD, wallet);
        FHE.allowThis(members[id].rewardPoints); FHE.allow(members[id].rewardPoints, wallet);
        FHE.allowThis(members[id].lifetimeSpendUSD); FHE.allow(members[id].lifetimeSpendUSD, wallet);
        FHE.allowThis(members[id].accessPrivilegeBitfield); FHE.allow(members[id].accessPrivilegeBitfield, wallet);
        FHE.allowThis(_totalRevenueUSD);
        emit MemberJoined(id, tier);
    }

    function upgradeMember(uint256 memberId, MembershipTier newTier, externalEuint16 encNewPrivileges, bytes calldata proof) external onlyClubManager {
        Member storage m = members[memberId];
        euint16 newPrivileges = FHE.fromExternal(encNewPrivileges, proof);
        m.tier = newTier;
        m.accessPrivilegeBitfield = newPrivileges;
        FHE.allowThis(m.accessPrivilegeBitfield); FHE.allow(m.accessPrivilegeBitfield, m.wallet);
        emit MemberUpgraded(memberId, newTier);
    }

    function awardPoints(uint256 memberId, string calldata eventType, externalEuint64 encPoints, bytes calldata proof) external onlyClubManager returns (uint256 eventId) {
        Member storage m = members[memberId];
        require(m.active, "Inactive member");
        euint64 points = FHE.fromExternal(encPoints, proof);
        m.rewardPoints = FHE.add(m.rewardPoints, points);
        _totalPointsIssued = FHE.add(_totalPointsIssued, points);
        eventId = rewardEventCount++;
        rewardEvents[eventId] = RewardEvent({ member: m.wallet, pointsEarned: points, eventType: eventType, earnedAt: block.timestamp });
        FHE.allowThis(m.rewardPoints); FHE.allow(m.rewardPoints, m.wallet);
        FHE.allowThis(rewardEvents[eventId].pointsEarned); FHE.allow(rewardEvents[eventId].pointsEarned, m.wallet);
        FHE.allowThis(_totalPointsIssued);
        emit PointsEarned(eventId, m.wallet);
    }

    function redeemPoints(uint256 memberId, externalEuint64 encRedeemAmt, bytes calldata proof) external nonReentrant {
        Member storage m = members[memberId];
        require(m.wallet == msg.sender && m.active, "Not your membership");
        euint64 redeemAmt = FHE.fromExternal(encRedeemAmt, proof);
        ebool sufficient = FHE.ge(m.rewardPoints, redeemAmt);
        euint64 effRedeem = FHE.select(sufficient, redeemAmt, m.rewardPoints);
        m.rewardPoints = FHE.sub(m.rewardPoints, effRedeem);
        FHE.allowThis(m.rewardPoints); FHE.allow(m.rewardPoints, msg.sender);
        emit PointsRedeemed(msg.sender, block.timestamp);
    }

    function renewSubscription(uint256 memberId, uint256 months, externalEuint64 encFee, bytes calldata proof) external onlyClubManager {
        Member storage m = members[memberId];
        euint64 fee = FHE.fromExternal(encFee, proof);
        m.subscriptionExpiry += months * 30 days;
        m.lifetimeSpendUSD = FHE.add(m.lifetimeSpendUSD, fee);
        _totalRevenueUSD = FHE.add(_totalRevenueUSD, fee);
        FHE.allowThis(m.lifetimeSpendUSD); FHE.allow(m.lifetimeSpendUSD, m.wallet);
        FHE.allowThis(_totalRevenueUSD);
    }

    function allowClubStats(address viewer) external onlyOwner {
        FHE.allow(_totalRevenueUSD, viewer); FHE.allow(_totalPointsIssued, viewer);
    }
    function getRewardPoints(address wallet) external view returns (euint64) { return members[memberIdByWallet[wallet]].rewardPoints; }
}
