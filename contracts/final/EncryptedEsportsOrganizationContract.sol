// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedEsportsOrganizationContract
/// @notice Encrypted professional esports contracts: confidential player salaries,
///         private performance bonuses, encrypted roster buy-outs, and
///         confidential prize pool distributions.
contract EncryptedEsportsOrganizationContract is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    enum GameTitle { DOTA2, CSGO, LOL, VALORANT, FORTNITE, APEX, OVERWATCH, STARCRAFT }
    enum ContractTier { ACADEMY, SEMI_PRO, PRO, FRANCHISE, SUPERSTAR }

    struct PlayerContract {
        address player;
        GameTitle game;
        ContractTier tier;
        euint64 baseSalaryMonthlyUSD;     // encrypted monthly base salary
        euint64 performanceBonusPoolUSD;  // encrypted annual bonus pool
        euint64 prizeShareBps;            // encrypted prize pool share percentage
        euint64 signingBonusUSD;          // encrypted signing bonus
        euint64 buyoutClauseUSD;          // encrypted buyout clause value
        euint64 streamingRoyaltyBps;      // encrypted streaming revenue share
        euint64 totalEarnedUSD;           // encrypted total earnings to date
        uint256 contractStart;
        uint256 contractEnd;
        bool active;
        bool suspended;
    }

    struct TournamentResult {
        uint256 tournamentId;
        address[] teamRoster;
        euint64 prizeWonUSD;          // encrypted prize amount
        euint32 placement;            // encrypted final placement
        bool distributed;
    }

    struct PerformanceMetric {
        address player;
        GameTitle game;
        euint64 kdaRatioBps;          // encrypted KDA ratio (scaled bps)
        euint64 winRateBps;           // encrypted win rate (bps)
        euint64 averageRatingBps;     // encrypted performance rating
        euint64 tournamentPointsBps;  // encrypted tournament ranking points
        uint256 assessmentDate;
    }

    struct BuyoutOffer {
        address offeringOrg;
        address player;
        euint64 offerAmountUSD;       // encrypted offer amount
        uint256 offerExpiry;
        bool accepted;
        bool active;
    }

    mapping(address => PlayerContract) private playerContracts;
    mapping(uint256 => TournamentResult) private tournamentResults;
    mapping(bytes32 => PerformanceMetric) private performanceMetrics; // keccak(player, periodId)
    mapping(uint256 => BuyoutOffer) private buyoutOffers;
    mapping(address => bool) public isTeamManager;
    mapping(address => bool) public isTournamentOrganizer;

    uint256 public tournamentCount;
    uint256 public buyoutOfferCount;
    euint64 private _totalOrganizationPayroll;
    euint64 private _totalPrizeEarnings;
    euint64 private _organizationRevenueUSD;

    event PlayerSigned(address indexed player, GameTitle game, ContractTier tier);
    event SalaryPaid(address indexed player, uint256 month);
    event TournamentRegistered(uint256 indexed tournamentId);
    event PrizeDistributed(uint256 indexed tournamentId);
    event BuyoutOfferReceived(uint256 indexed offerId, address player);
    event BuyoutAccepted(uint256 indexed offerId);
    event PerformanceBonusAwarded(address indexed player);
    event PlayerSuspended(address indexed player);

    constructor() Ownable(msg.sender) {
        _totalOrganizationPayroll = FHE.asEuint64(0);
        _totalPrizeEarnings = FHE.asEuint64(0);
        _organizationRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalOrganizationPayroll);
        FHE.allowThis(_totalPrizeEarnings);
        FHE.allowThis(_organizationRevenueUSD);
        isTeamManager[msg.sender] = true;
        isTournamentOrganizer[msg.sender] = true;
    }

    modifier onlyTeamManager() { require(isTeamManager[msg.sender], "Not team manager"); _; }

    function signPlayer(
        address player,
        GameTitle game,
        ContractTier tier,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint64 encBonusPool, bytes calldata bpProof,
        externalEuint64 encPrizeShare, bytes calldata psProof,
        externalEuint64 encSigningBonus, bytes calldata sbProof,
        externalEuint64 encBuyout, bytes calldata boProof,
        externalEuint64 encStreamingRoyalty, bytes calldata srProof,
        uint256 contractStart, uint256 contractEnd
    ) external onlyTeamManager {
        require(!playerContracts[player].active, "Player already contracted");
        PlayerContract storage pc = playerContracts[player];
        pc.player = player;
        pc.game = game;
        pc.tier = tier;
        pc.baseSalaryMonthlyUSD = FHE.fromExternal(encSalary, sProof);
        pc.performanceBonusPoolUSD = FHE.fromExternal(encBonusPool, bpProof);
        pc.prizeShareBps = FHE.fromExternal(encPrizeShare, psProof);
        pc.signingBonusUSD = FHE.fromExternal(encSigningBonus, sbProof);
        pc.buyoutClauseUSD = FHE.fromExternal(encBuyout, boProof);
        pc.streamingRoyaltyBps = FHE.fromExternal(encStreamingRoyalty, srProof);
        pc.totalEarnedUSD = pc.signingBonusUSD; // Signing bonus paid upfront
        pc.contractStart = contractStart;
        pc.contractEnd = contractEnd;
        pc.active = true;
        ebool _safeMul58 = FHE.le(pc.baseSalaryMonthlyUSD, FHE.asEuint64(type(uint64).max / 12));
        _totalOrganizationPayroll = FHE.add(_totalOrganizationPayroll, FHE.mul(pc.baseSalaryMonthlyUSD, FHE.asEuint64(12)));
        FHE.allowThis(pc.baseSalaryMonthlyUSD);
        FHE.allow(pc.baseSalaryMonthlyUSD, player);
        FHE.allowThis(pc.performanceBonusPoolUSD);
        FHE.allow(pc.performanceBonusPoolUSD, player);
        FHE.allowThis(pc.prizeShareBps);
        FHE.allow(pc.prizeShareBps, player);
        FHE.allowThis(pc.signingBonusUSD);
        FHE.allow(pc.signingBonusUSD, player);
        FHE.allowThis(pc.buyoutClauseUSD);
        FHE.allowThis(pc.streamingRoyaltyBps);
        FHE.allow(pc.streamingRoyaltyBps, player);
        FHE.allowThis(pc.totalEarnedUSD);
        FHE.allow(pc.totalEarnedUSD, player);
        FHE.allowThis(_totalOrganizationPayroll);
        emit PlayerSigned(player, game, tier);
    }

    function paySalary(address player, uint256 month) external onlyTeamManager whenNotPaused {
        PlayerContract storage pc = playerContracts[player];
        require(pc.active && !pc.suspended, "Player not active");
        require(block.timestamp >= pc.contractStart && block.timestamp <= pc.contractEnd, "Outside contract period");
        pc.totalEarnedUSD = FHE.add(pc.totalEarnedUSD, pc.baseSalaryMonthlyUSD);
        FHE.allowThis(pc.totalEarnedUSD);
        FHE.allow(pc.totalEarnedUSD, player);
        FHE.allowTransient(pc.baseSalaryMonthlyUSD, player);
        emit SalaryPaid(player, month);
    }

    function recordTournamentResult(
        address[] calldata roster,
        externalEuint64 encPrize, bytes calldata pProof,
        externalEuint32 encPlacement, bytes calldata plProof
    ) external returns (uint256 tournamentId) {
        require(isTournamentOrganizer[msg.sender], "Not organizer");
        euint64 prize = FHE.fromExternal(encPrize, pProof);
        euint32 placement = FHE.fromExternal(encPlacement, plProof);
        tournamentId = tournamentCount++;
        TournamentResult storage tr = tournamentResults[tournamentId];
        tr.tournamentId = tournamentId;
        tr.teamRoster = roster;
        tr.prizeWonUSD = prize;
        tr.placement = placement;
        _totalPrizeEarnings = FHE.add(_totalPrizeEarnings, prize);
        FHE.allowThis(tr.prizeWonUSD);
        FHE.allowThis(tr.placement);
        FHE.allowThis(_totalPrizeEarnings);
        emit TournamentRegistered(tournamentId);
    }

    function distributePrize(uint256 tournamentId) external onlyTeamManager nonReentrant {
        TournamentResult storage tr = tournamentResults[tournamentId];
        require(!tr.distributed, "Already distributed");
        tr.distributed = true;
        for (uint256 i = 0; i < tr.teamRoster.length; i++) {
            address player = tr.teamRoster[i];
            PlayerContract storage pc = playerContracts[player];
            if (!pc.active) continue;
            euint64 playerShare = FHE.div(FHE.mul(tr.prizeWonUSD, pc.prizeShareBps), 10000);
            pc.totalEarnedUSD = FHE.add(pc.totalEarnedUSD, playerShare);
            FHE.allowThis(pc.totalEarnedUSD);
            FHE.allow(pc.totalEarnedUSD, player);
            FHE.allowTransient(playerShare, player);
        }
        emit PrizeDistributed(tournamentId);
    }

    function recordPerformance(
        address player, uint256 periodId,
        externalEuint64 encKDA, bytes calldata kdaProof,
        externalEuint64 encWinRate, bytes calldata wrProof,
        externalEuint64 encRating, bytes calldata rProof
    ) external onlyTeamManager {
        bytes32 metricKey = keccak256(abi.encodePacked(player, periodId));
        PlayerContract storage pc = playerContracts[player];
        euint64 kda = FHE.fromExternal(encKDA, kdaProof);
        euint64 winRate = FHE.fromExternal(encWinRate, wrProof);
        euint64 rating = FHE.fromExternal(encRating, rProof);
        performanceMetrics[metricKey] = PerformanceMetric({
            player: player, game: pc.game,
            kdaRatioBps: kda, winRateBps: winRate,
            averageRatingBps: rating, tournamentPointsBps: FHE.asEuint64(0),
            assessmentDate: block.timestamp
        });
        FHE.allowThis(performanceMetrics[metricKey].kdaRatioBps);
        FHE.allow(performanceMetrics[metricKey].kdaRatioBps, player);
        FHE.allowThis(performanceMetrics[metricKey].winRateBps);
        FHE.allow(performanceMetrics[metricKey].winRateBps, player);
        FHE.allowThis(performanceMetrics[metricKey].averageRatingBps);
        FHE.allow(performanceMetrics[metricKey].averageRatingBps, player);
    }

    function awardPerformanceBonus(
        address player,
        externalEuint64 encBonusAmount, bytes calldata baProof
    ) external onlyTeamManager {
        PlayerContract storage pc = playerContracts[player];
        require(pc.active, "Player not active");
        euint64 bonus = FHE.fromExternal(encBonusAmount, baProof);
        // Cap at performance bonus pool
        ebool withinPool = FHE.le(bonus, pc.performanceBonusPoolUSD);
        euint64 actualBonus = FHE.select(withinPool, bonus, pc.performanceBonusPoolUSD);
        pc.totalEarnedUSD = FHE.add(pc.totalEarnedUSD, actualBonus);
        ebool _safeSub220 = FHE.ge(pc.performanceBonusPoolUSD, actualBonus);
        pc.performanceBonusPoolUSD = FHE.select(_safeSub220, FHE.sub(pc.performanceBonusPoolUSD, actualBonus), FHE.asEuint64(0));
        FHE.allowThis(pc.totalEarnedUSD);
        FHE.allow(pc.totalEarnedUSD, player);
        FHE.allowThis(pc.performanceBonusPoolUSD);
        FHE.allow(pc.performanceBonusPoolUSD, player);
        FHE.allowTransient(actualBonus, player);
        emit PerformanceBonusAwarded(player);
    }

    function receiveBuyoutOffer(
        address player,
        externalEuint64 encOffer, bytes calldata oProof,
        uint256 expiryDate
    ) external nonReentrant returns (uint256 offerId) {
        PlayerContract storage pc = playerContracts[player];
        require(pc.active, "Not active");
        euint64 offer = FHE.fromExternal(encOffer, oProof);
        // Offer must meet buyout clause
        ebool meetsClause = FHE.ge(offer, pc.buyoutClauseUSD);
        offerId = buyoutOfferCount++;
        buyoutOffers[offerId] = BuyoutOffer({
            offeringOrg: msg.sender, player: player,
            offerAmountUSD: FHE.select(meetsClause, offer, pc.buyoutClauseUSD),
            offerExpiry: expiryDate, accepted: false, active: true
        });
        FHE.allowThis(buyoutOffers[offerId].offerAmountUSD);
        FHE.allow(buyoutOffers[offerId].offerAmountUSD, player);
        FHE.allow(buyoutOffers[offerId].offerAmountUSD, msg.sender);
        emit BuyoutOfferReceived(offerId, player);
    }

    function acceptBuyout(uint256 offerId) external onlyTeamManager {
        BuyoutOffer storage bo = buyoutOffers[offerId];
        require(bo.active && !bo.accepted, "Invalid offer");
        require(block.timestamp <= bo.offerExpiry, "Offer expired");
        bo.accepted = true;
        playerContracts[bo.player].active = false;
        _organizationRevenueUSD = FHE.add(_organizationRevenueUSD, bo.offerAmountUSD);
        FHE.allowThis(_organizationRevenueUSD);
        emit BuyoutAccepted(offerId);
    }

    function suspendPlayer(address player) external onlyTeamManager {
        playerContracts[player].suspended = true;
        emit PlayerSuspended(player);
    }

    function reinstatePlayer(address player) external onlyTeamManager {
        playerContracts[player].suspended = false;
    }

    function addTeamManager(address tm) external onlyOwner { isTeamManager[tm] = true; }
    function addTournamentOrganizer(address to_) external onlyOwner { isTournamentOrganizer[to_] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function allowOrgStats(address analyst) external onlyOwner {
        FHE.allow(_totalOrganizationPayroll, analyst);
        FHE.allow(_totalPrizeEarnings, analyst);
        FHE.allow(_organizationRevenueUSD, analyst);
    }
}
