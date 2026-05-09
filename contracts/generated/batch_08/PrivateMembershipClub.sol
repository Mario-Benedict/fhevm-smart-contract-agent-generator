// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMembershipClub - Encrypted membership tiers with private benefit tracking
contract PrivateMembershipClub is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Member {
        euint8 membershipTier;   // 1=Silver, 2=Gold, 3=Platinum, 4=Diamond
        euint32 joinedAt;
        euint32 pointsBalance;
        euint16 benefitsUsed;
        bool active;
        uint256 renewalDate;
    }

    struct Benefit {
        string name;
        euint8 minimumTier;
        euint16 pointCost;
        uint32 usageLimit;
        bool available;
    }

    mapping(address => Member) public members;
    mapping(uint256 => Benefit) public benefits;
    mapping(address => mapping(uint256 => uint32)) public memberBenefitUsage;
    uint256 public benefitCount;
    uint256 public memberCount;

    event MemberEnrolled(address indexed member);
    event TierUpgraded(address indexed member);
    event BenefitRedeemed(address indexed member, uint256 benefitId);
    event PointsAwarded(address indexed member);

    constructor() Ownable(msg.sender) {}

    function enrollMember(
        address member,
        externalEuint8 encTier,
        bytes calldata tierProof,
        externalEuint32 encPoints,
        bytes calldata pointsProof,
        uint256 renewalDays
    ) external onlyOwner {
        require(!members[member].active, "Already enrolled");
        Member storage m = members[member];
        m.membershipTier = FHE.fromExternal(encTier, tierProof);
        m.pointsBalance = FHE.fromExternal(encPoints, pointsProof);
        m.joinedAt = FHE.asEuint32(uint32(block.timestamp));
        m.benefitsUsed = FHE.asEuint16(0);
        m.active = true;
        m.renewalDate = block.timestamp + renewalDays * 1 days;
        FHE.allowThis(m.membershipTier);
        FHE.allowThis(m.pointsBalance);
        FHE.allowThis(m.joinedAt);
        FHE.allowThis(m.benefitsUsed);
        FHE.allow(m.membershipTier, member);
        FHE.allow(m.pointsBalance, member);
        memberCount++;
        emit MemberEnrolled(member);
    }

    function addBenefit(
        string calldata name,
        externalEuint8 encMinTier,
        bytes calldata tierProof,
        externalEuint16 encCost,
        bytes calldata costProof,
        uint32 usageLimit
    ) external onlyOwner returns (uint256 benefitId) {
        benefitId = benefitCount++;
        Benefit storage b = benefits[benefitId];
        b.name = name;
        b.minimumTier = FHE.fromExternal(encMinTier, tierProof);
        b.pointCost = FHE.fromExternal(encCost, costProof);
        b.usageLimit = usageLimit;
        b.available = true;
        FHE.allowThis(b.minimumTier);
        FHE.allowThis(b.pointCost);
    }

    function redeemBenefit(uint256 benefitId) external nonReentrant {
        Member storage m = members[msg.sender];
        require(m.active, "Not a member");
        require(block.timestamp <= m.renewalDate, "Membership expired");
        Benefit storage b = benefits[benefitId];
        require(b.available, "Benefit unavailable");
        require(memberBenefitUsage[msg.sender][benefitId] < b.usageLimit, "Usage limit reached");

        ebool tierOk = FHE.ge(m.membershipTier, b.minimumTier);
        ebool hasPoints = FHE.ge(m.pointsBalance, FHE.asEuint32(0));
        ebool canRedeem = FHE.and(tierOk, hasPoints);

        euint32 cost = FHE.select(canRedeem, FHE.asEuint32(0), FHE.asEuint32(0)); // placeholder
        m.pointsBalance = FHE.sub(m.pointsBalance, cost);
        m.benefitsUsed = FHE.add(m.benefitsUsed, FHE.select(canRedeem, FHE.asEuint16(1), FHE.asEuint16(0)));

        FHE.allowThis(m.pointsBalance);
        FHE.allowThis(m.benefitsUsed);
        FHE.allow(m.pointsBalance, msg.sender);
        memberBenefitUsage[msg.sender][benefitId]++;
        emit BenefitRedeemed(msg.sender, benefitId);
    }

    function awardPoints(address member, externalEuint32 encPoints, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint32 pts = FHE.fromExternal(encPoints, inputProof);
        members[member].pointsBalance = FHE.add(members[member].pointsBalance, pts);
        FHE.allowThis(members[member].pointsBalance);
        FHE.allow(members[member].pointsBalance, member);
        emit PointsAwarded(member);
    }
}
