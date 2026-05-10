// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMicrofinanceSavingsGroup
/// @notice Encrypted village savings and loan association: hidden member savings balances,
///         confidential loan amounts and repayments, private group credit scoring,
///         and encrypted profit sharing at cycle end.
contract PrivateMicrofinanceSavingsGroup is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum GroupStatus { Forming, Active, Lending, DistributingProfits, Closed }

    struct SavingsGroup {
        string groupName;
        string communityRef;
        address facilitator;
        euint64 totalSavingsUSD;       // encrypted total savings
        euint64 loanFundUSD;           // encrypted loan fund
        euint64 interestAccruedUSD;    // encrypted interest collected
        euint32 activeMemberCount;     // encrypted active members
        euint16 cycleInterestRateBps;  // encrypted cycle interest rate
        GroupStatus status;
        uint256 cycleStart;
        uint256 cycleEnd;
    }

    struct GroupMember {
        uint256 groupId;
        address member;
        euint64 savingsBalanceUSD;     // encrypted savings
        euint64 activeLoanUSD;         // encrypted outstanding loan
        euint64 repaidLoanUSD;         // encrypted repaid amount
        euint64 profitShareUSD;        // encrypted profit at cycle end
        euint8  creditScore;           // encrypted credit score (0-100)
        bool active;
    }

    mapping(uint256 => SavingsGroup) private groups;
    mapping(uint256 => GroupMember) private groupMembers;
    mapping(address => bool) public isMFInstitution;

    uint256 public groupCount;
    uint256 public memberCount;
    euint64 private _totalCommunityWealthUSD;

    event GroupCreated(uint256 indexed id, string groupName);
    event MemberJoined(uint256 indexed memberId, uint256 groupId);
    event SavingsDeposited(uint256 indexed memberId, uint256 depositedAt);
    event LoanDisbursed(uint256 indexed memberId, uint256 disbursedAt);
    event ProfitDistributed(uint256 indexed groupId);

    modifier onlyMFInstitution() {
        require(isMFInstitution[msg.sender] || msg.sender == owner(), "Not MFI");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCommunityWealthUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCommunityWealthUSD);
        isMFInstitution[msg.sender] = true;
    }

    function addMFI(address m) external onlyOwner { isMFInstitution[m] = true; }

    function createGroup(
        string calldata groupName, string calldata communityRef,
        externalEuint16 encCycleRate, bytes calldata crProof,
        uint256 cycleDays
    ) external onlyMFInstitution returns (uint256 id) {
        euint16 cycleRate = FHE.fromExternal(encCycleRate, crProof);
        id = groupCount++;
        groups[id].groupName = groupName;
        groups[id].communityRef = communityRef;
        groups[id].facilitator = msg.sender;
        groups[id].totalSavingsUSD = FHE.asEuint64(0);
        groups[id].loanFundUSD = FHE.asEuint64(0);
        groups[id].interestAccruedUSD = FHE.asEuint64(0);
        groups[id].activeMemberCount = FHE.asEuint32(0);
        groups[id].cycleInterestRateBps = cycleRate;
        groups[id].status = GroupStatus.Forming;
        groups[id].cycleStart = block.timestamp;
        groups[id].cycleEnd = block.timestamp + cycleDays * 1 days;
        FHE.allowThis(groups[id].totalSavingsUSD); FHE.allow(groups[id].totalSavingsUSD, msg.sender);
        FHE.allowThis(groups[id].loanFundUSD); FHE.allow(groups[id].loanFundUSD, msg.sender);
        FHE.allowThis(groups[id].interestAccruedUSD); FHE.allow(groups[id].interestAccruedUSD, msg.sender);
        FHE.allowThis(groups[id].activeMemberCount);
        FHE.allowThis(groups[id].cycleInterestRateBps);
        emit GroupCreated(id, groupName);
    }

    function joinGroup(uint256 groupId) external returns (uint256 memberId) {
        SavingsGroup storage g = groups[groupId];
        require(g.status == GroupStatus.Forming || g.status == GroupStatus.Active, "Not accepting members");
        memberId = memberCount++;
        groupMembers[memberId] = GroupMember({
            groupId: groupId, member: msg.sender, savingsBalanceUSD: FHE.asEuint64(0),
            activeLoanUSD: FHE.asEuint64(0), repaidLoanUSD: FHE.asEuint64(0),
            profitShareUSD: FHE.asEuint64(0), creditScore: FHE.asEuint8(50), active: true
        });
        g.activeMemberCount = FHE.add(g.activeMemberCount, FHE.asEuint32(1));
        FHE.allowThis(groupMembers[memberId].savingsBalanceUSD); FHE.allow(groupMembers[memberId].savingsBalanceUSD, msg.sender);
        FHE.allowThis(groupMembers[memberId].activeLoanUSD); FHE.allow(groupMembers[memberId].activeLoanUSD, msg.sender);
        FHE.allowThis(groupMembers[memberId].repaidLoanUSD); FHE.allow(groupMembers[memberId].repaidLoanUSD, msg.sender);
        FHE.allowThis(groupMembers[memberId].profitShareUSD); FHE.allow(groupMembers[memberId].profitShareUSD, msg.sender);
        FHE.allowThis(groupMembers[memberId].creditScore); FHE.allow(groupMembers[memberId].creditScore, msg.sender);
        FHE.allowThis(g.activeMemberCount);
        emit MemberJoined(memberId, groupId);
    }

    function depositSavings(
        uint256 memberId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        GroupMember storage m = groupMembers[memberId];
        require(msg.sender == m.member && m.active, "Not authorized");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        m.savingsBalanceUSD = FHE.add(m.savingsBalanceUSD, amount);
        SavingsGroup storage g = groups[m.groupId];
        g.totalSavingsUSD = FHE.add(g.totalSavingsUSD, amount);
        g.loanFundUSD = FHE.add(g.loanFundUSD, amount);
        _totalCommunityWealthUSD = FHE.add(_totalCommunityWealthUSD, amount);
        FHE.allowThis(m.savingsBalanceUSD); FHE.allow(m.savingsBalanceUSD, m.member);
        FHE.allowThis(g.totalSavingsUSD); FHE.allow(g.totalSavingsUSD, g.facilitator);
        FHE.allowThis(g.loanFundUSD); FHE.allow(g.loanFundUSD, g.facilitator);
        FHE.allowThis(_totalCommunityWealthUSD);
        emit SavingsDeposited(memberId, block.timestamp);
    }

    function issueLoan(
        uint256 memberId,
        externalEuint64 encLoanAmt, bytes calldata proof
    ) external onlyMFInstitution nonReentrant {
        GroupMember storage m = groupMembers[memberId];
        SavingsGroup storage g = groups[m.groupId];
        euint64 loanAmt = FHE.fromExternal(encLoanAmt, proof);
        ebool fundSufficient = FHE.ge(g.loanFundUSD, loanAmt);
        euint64 effectiveLoan = FHE.select(fundSufficient, loanAmt, FHE.asEuint64(0));
        m.activeLoanUSD = FHE.add(m.activeLoanUSD, effectiveLoan);
        g.loanFundUSD = FHE.sub(g.loanFundUSD, effectiveLoan);
        FHE.allowThis(m.activeLoanUSD); FHE.allow(m.activeLoanUSD, m.member);
        FHE.allowThis(g.loanFundUSD); FHE.allow(g.loanFundUSD, g.facilitator);
        emit LoanDisbursed(memberId, block.timestamp);
    }

    function allowGroupStats(address viewer) external onlyOwner {
        FHE.allow(_totalCommunityWealthUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalCommunityWealthUSD, msg.sender); // [acl_misconfig]
    }
}
