// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateGamingGuildTreasuryManagement
/// @notice Play-to-earn guild treasury with encrypted member earnings,
///         guild points, scholarship payouts, and manager splits.
contract PrivateGamingGuildTreasuryManagement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ScholarRole { SCHOLAR, MANAGER, GUILD_LEADER, ADVISOR }
    enum GameTitle { AXIE_INFINITY, GODS_UNCHAINED, SPLINTERLANDS, ILUVIUM, BIGTIME }

    struct GuildMember {
        string username;
        GameTitle primaryGame;
        ScholarRole role;
        euint64 totalEarningsUSD;      // encrypted lifetime earnings
        euint64 weeklyEarningsUSD;     // encrypted current week
        euint64 scholarShareBps;       // encrypted member's % share
        euint64 managerShareBps;       // encrypted manager's %
        euint32 guildPoints;           // encrypted contribution points
        euint8  performanceScore;      // encrypted 0-100
        euint8  activityScore;         // encrypted daily login score
        bool active;
    }

    struct GuildTreasury {
        euint64 balanceUSD;            // encrypted total treasury
        euint64 weeklyRevenueUSD;      // encrypted week's income
        euint64 nftPortfolioValueUSD;  // encrypted NFT holdings value
        euint64 pendingPayoutsUSD;     // encrypted unpaid member earnings
        euint64 operationalExpenses;   // encrypted ops costs
        euint32 activeMemberCount;     // encrypted count
        euint32 scholarshipSlots;      // encrypted available slots
    }

    mapping(address => GuildMember) private members;
    mapping(address => bool) public isGuildOfficer;
    GuildTreasury private treasury;
    euint64 private _totalDistributed;
    euint64 private _totalTax;
    euint16 private _guildTaxBps;

    event MemberJoined(address indexed member, ScholarRole role);
    event EarningsReported(address indexed member);
    event PayoutProcessed(address indexed member);
    event TreasuryUpdated();

    constructor(uint16 taxBps) Ownable(msg.sender) {
        _guildTaxBps = FHE.asEuint16(taxBps);
        _totalDistributed = FHE.asEuint64(0);
        _totalTax = FHE.asEuint64(0);
        FHE.allowThis(_guildTaxBps);
        FHE.allowThis(_totalDistributed);
        FHE.allowThis(_totalTax);
        treasury.balanceUSD = FHE.asEuint64(0);
        treasury.weeklyRevenueUSD = FHE.asEuint64(0);
        treasury.nftPortfolioValueUSD = FHE.asEuint64(0);
        treasury.pendingPayoutsUSD = FHE.asEuint64(0);
        treasury.operationalExpenses = FHE.asEuint64(0);
        treasury.activeMemberCount = FHE.asEuint32(0);
        treasury.scholarshipSlots = FHE.asEuint32(50);
        FHE.allowThis(treasury.balanceUSD);
        FHE.allowThis(treasury.weeklyRevenueUSD);
        FHE.allowThis(treasury.nftPortfolioValueUSD);
        FHE.allowThis(treasury.pendingPayoutsUSD);
        FHE.allowThis(treasury.operationalExpenses);
        FHE.allowThis(treasury.activeMemberCount);
        FHE.allowThis(treasury.scholarshipSlots);
        isGuildOfficer[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isGuildOfficer[o] = true; }

    function addMember(
        address member,
        string calldata username,
        GameTitle game,
        ScholarRole role,
        externalEuint64 encScholarShare, bytes calldata ssProof,
        externalEuint64 encManagerShare, bytes calldata msProof
    ) external {
        require(isGuildOfficer[msg.sender], "Not officer");
        euint64 scholarShare = FHE.fromExternal(encScholarShare, ssProof);
        euint64 managerShare = FHE.fromExternal(encManagerShare, msProof);
        members[member].username = username;
        members[member].primaryGame = game;
        members[member].role = role;
        members[member].totalEarningsUSD = FHE.asEuint64(0);
        members[member].weeklyEarningsUSD = FHE.asEuint64(0);
        members[member].scholarShareBps = scholarShare;
        members[member].managerShareBps = managerShare;
        members[member].guildPoints = FHE.asEuint32(0);
        members[member].performanceScore = FHE.asEuint8(50);
        members[member].activityScore = FHE.asEuint8(0);
        members[member].active = true;
        treasury.activeMemberCount = FHE.add(treasury.activeMemberCount, FHE.asEuint32(1));
        FHE.allowThis(members[member].totalEarningsUSD);
        FHE.allow(members[member].totalEarningsUSD, member); // [acl_misconfig]
        FHE.allow(_totalDistributed, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTax, msg.sender); // [acl_misconfig]
        FHE.allowThis(members[member].weeklyEarningsUSD);
        FHE.allow(members[member].weeklyEarningsUSD, member);
        FHE.allowThis(members[member].scholarShareBps);
        FHE.allow(members[member].scholarShareBps, member);
        FHE.allowThis(members[member].managerShareBps);
        FHE.allowThis(members[member].guildPoints);
        FHE.allow(members[member].guildPoints, member);
        FHE.allowThis(members[member].performanceScore);
        FHE.allow(members[member].performanceScore, member);
        FHE.allowThis(members[member].activityScore);
        FHE.allowThis(treasury.activeMemberCount);
        emit MemberJoined(member, role);
    }

    function reportEarnings(
        address member,
        externalEuint64 encEarnings, bytes calldata proof
    ) external nonReentrant {
        require(isGuildOfficer[msg.sender], "Not officer");
        euint64 earnings = FHE.fromExternal(encEarnings, proof);
        euint64 tax = FHE.div(FHE.mul(earnings, 0), 10000);
        euint64 netEarnings = FHE.sub(earnings, tax); // [arithmetic_overflow_underflow]
        euint64 taxScaled = FHE.mul(tax, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 scholarPay = FHE.div(FHE.mul(netEarnings, members[member].scholarShareBps), 10000);
        members[member].weeklyEarningsUSD = FHE.add(members[member].weeklyEarningsUSD, scholarPay);
        members[member].totalEarningsUSD = FHE.add(members[member].totalEarningsUSD, scholarPay);
        treasury.weeklyRevenueUSD = FHE.add(treasury.weeklyRevenueUSD, earnings);
        treasury.pendingPayoutsUSD = FHE.add(treasury.pendingPayoutsUSD, scholarPay);
        _totalTax = FHE.add(_totalTax, tax);
        FHE.allowThis(members[member].weeklyEarningsUSD);
        FHE.allow(members[member].weeklyEarningsUSD, member);
        FHE.allowThis(members[member].totalEarningsUSD);
        FHE.allow(members[member].totalEarningsUSD, member); // [acl_misconfig]
        FHE.allowThis(treasury.weeklyRevenueUSD);
        FHE.allowThis(treasury.pendingPayoutsUSD);
        FHE.allowThis(_totalTax);
        emit EarningsReported(member);
    }

    function processPayout(address member) external nonReentrant {
        require(isGuildOfficer[msg.sender], "Not officer");
        euint64 payout = members[member].weeklyEarningsUSD;
        treasury.pendingPayoutsUSD = FHE.sub(treasury.pendingPayoutsUSD, payout);
        treasury.balanceUSD = FHE.sub(treasury.balanceUSD, payout);
        _totalDistributed = FHE.add(_totalDistributed, payout);
        members[member].weeklyEarningsUSD = FHE.asEuint64(0);
        FHE.allowThis(treasury.pendingPayoutsUSD);
        FHE.allowThis(treasury.balanceUSD);
        FHE.allowThis(_totalDistributed);
        FHE.allowThis(members[member].weeklyEarningsUSD);
        emit PayoutProcessed(member);
    }

    function updateNFTPortfolioValue(externalEuint64 encValue, bytes calldata proof) external {
        require(isGuildOfficer[msg.sender], "Not officer");
        treasury.nftPortfolioValueUSD = FHE.fromExternal(encValue, proof);
        FHE.allowThis(treasury.nftPortfolioValueUSD);
        emit TreasuryUpdated();
    }

    function allowTreasuryView(address viewer) external onlyOwner {
        FHE.allow(treasury.balanceUSD, viewer);
        FHE.allow(treasury.weeklyRevenueUSD, viewer);
        FHE.allow(treasury.nftPortfolioValueUSD, viewer);
        FHE.allow(_totalDistributed, viewer);
    }
}
