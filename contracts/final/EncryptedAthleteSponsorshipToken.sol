// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAthleteSponsorshipToken
/// @notice Encrypted athlete sponsorship: private performance bonuses, hidden
///         contract values, confidential exclusivity scores, and encrypted
///         revenue share from brand endorsements.
contract EncryptedAthleteSponsorshipToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Athlete Sponsor Token";
    string public constant symbol = "AST";
    uint8  public constant decimals = 18;

    enum SportCategory { Football, Basketball, Tennis, Golf, Swimming, Athletics, eSports }

    struct AthleteProfile {
        address athleteWallet;
        SportCategory sport;
        string athleteRef;
        euint64 baseContractValueUSD;  // encrypted base contract
        euint64 performanceBonusUSD;   // encrypted bonus pool
        euint64 endorsementRevenueUSD; // encrypted endorsement revenue
        euint64 brandExclusivityScore; // encrypted exclusivity
        euint16 socialFollowersM;      // encrypted social reach (millions)
        euint16 performanceRating;     // encrypted performance index
        bool active;
    }

    struct SponsorshipDeal {
        uint256 athleteId;
        address sponsor;
        string  brandRef;
        euint64 dealValueUSD;          // encrypted deal value
        euint64 revenueShareBps;       // encrypted revenue share
        euint64 earningsToAthlete;     // encrypted athlete earnings
        uint256 dealDate;
        uint256 termMonths;
        bool exclusive;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => AthleteProfile) private athletes;
    mapping(address => uint256) private athleteIdByWallet;
    mapping(uint256 => SponsorshipDeal) private deals;

    euint64 private _totalSupply;
    euint64 private _totalSponsorshipRevenueUSD;
    euint64 private _totalAthleteEarningsUSD;

    uint256 public athleteCount;
    uint256 public dealCount;

    event Transfer(address indexed from, address indexed to);
    event AthleteRegistered(uint256 indexed id, SportCategory sport);
    event SponsorshipDealSigned(uint256 indexed dealId, uint256 athleteId, address sponsor);
    event PerformanceBonusPaid(uint256 indexed athleteId, uint256 paidAt);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalSponsorshipRevenueUSD = FHE.asEuint64(0);
        _totalAthleteEarningsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_totalSponsorshipRevenueUSD); FHE.allowThis(_totalAthleteEarningsUSD);
    }

    function registerAthlete(
        SportCategory sport, string calldata athleteRef,
        externalEuint64 encBaseContract, bytes calldata bcProof,
        externalEuint16 encSocialFollowers, bytes calldata sfProof,
        externalEuint16 encPerformance, bytes calldata perfProof
    ) external returns (uint256 id) {
        euint64 baseContract    = FHE.fromExternal(encBaseContract, bcProof);
        euint16 socialFollowers = FHE.fromExternal(encSocialFollowers, sfProof);
        euint16 performance     = FHE.fromExternal(encPerformance, perfProof);
        id = athleteCount++;
        athleteIdByWallet[msg.sender] = id;
        athletes[id].athleteWallet = msg.sender;
        athletes[id].sport = sport;
        athletes[id].athleteRef = athleteRef;
        athletes[id].baseContractValueUSD = baseContract;
        athletes[id].performanceBonusUSD = FHE.asEuint64(0);
        athletes[id].endorsementRevenueUSD = FHE.asEuint64(0);
        athletes[id].brandExclusivityScore = FHE.asEuint64(0);
        athletes[id].socialFollowersM = socialFollowers;
        athletes[id].performanceRating = performance;
        athletes[id].active = true;
        // Mint AST tokens proportional to base contract
        euint64 tokensIssued = FHE.div(baseContract, 1000);
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], tokensIssued);
        _totalSupply = FHE.add(_totalSupply, tokensIssued);
        FHE.allowThis(athletes[id].baseContractValueUSD); FHE.allow(athletes[id].baseContractValueUSD, msg.sender);
        FHE.allowThis(athletes[id].performanceBonusUSD); FHE.allow(athletes[id].performanceBonusUSD, msg.sender);
        FHE.allowThis(athletes[id].endorsementRevenueUSD); FHE.allow(athletes[id].endorsementRevenueUSD, msg.sender);
        FHE.allowThis(athletes[id].brandExclusivityScore);
        FHE.allowThis(athletes[id].socialFollowersM); FHE.allow(athletes[id].socialFollowersM, msg.sender);
        FHE.allowThis(athletes[id].performanceRating); FHE.allow(athletes[id].performanceRating, msg.sender);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_totalSupply);
        emit AthleteRegistered(id, sport);
    }

    function signSponsorshipDeal(
        uint256 athleteId, string calldata brandRef,
        externalEuint64 encDealValue, bytes calldata dvProof,
        externalEuint64 encRevShare, bytes calldata rsProof,
        uint256 termMonths, bool exclusive
    ) external returns (uint256 dealId) {
        AthleteProfile storage a = athletes[athleteId];
        require(a.active, "Athlete inactive");
        euint64 dealValue = FHE.fromExternal(encDealValue, dvProof);
        euint64 revShare  = FHE.fromExternal(encRevShare, rsProof);
        euint64 athleteEarnings = FHE.div(FHE.mul(dealValue, revShare), 10000);
        a.endorsementRevenueUSD = FHE.add(a.endorsementRevenueUSD, athleteEarnings);
        _totalSponsorshipRevenueUSD = FHE.add(_totalSponsorshipRevenueUSD, dealValue);
        _totalAthleteEarningsUSD = FHE.add(_totalAthleteEarningsUSD, athleteEarnings);
        dealId = dealCount++;
        deals[dealId].athleteId = athleteId;
        deals[dealId].sponsor = msg.sender;
        deals[dealId].brandRef = brandRef;
        deals[dealId].dealValueUSD = dealValue;
        deals[dealId].revenueShareBps = revShare;
        deals[dealId].earningsToAthlete = athleteEarnings;
        deals[dealId].dealDate = block.timestamp;
        deals[dealId].termMonths = termMonths;
        deals[dealId].exclusive = exclusive;
        FHE.allowThis(a.endorsementRevenueUSD); FHE.allow(a.endorsementRevenueUSD, a.athleteWallet);
        FHE.allowThis(deals[dealId].dealValueUSD); FHE.allow(deals[dealId].dealValueUSD, msg.sender); FHE.allow(deals[dealId].dealValueUSD, a.athleteWallet);
        FHE.allowThis(deals[dealId].earningsToAthlete); FHE.allow(deals[dealId].earningsToAthlete, a.athleteWallet);
        FHE.allowThis(deals[dealId].revenueShareBps); FHE.allow(deals[dealId].revenueShareBps, a.athleteWallet);
        FHE.allowThis(_totalSponsorshipRevenueUSD); FHE.allowThis(_totalAthleteEarningsUSD);
        emit SponsorshipDealSigned(dealId, athleteId, msg.sender);
    }

    function payPerformanceBonus(uint256 athleteId, externalEuint64 encBonus, bytes calldata proof) external onlyOwner {
        AthleteProfile storage a = athletes[athleteId];
        euint64 bonus = FHE.fromExternal(encBonus, proof);
        a.performanceBonusUSD = FHE.add(a.performanceBonusUSD, bonus);
        _totalAthleteEarningsUSD = FHE.add(_totalAthleteEarningsUSD, bonus);
        FHE.allowThis(a.performanceBonusUSD); FHE.allow(a.performanceBonusUSD, a.athleteWallet);
        FHE.allow(bonus, a.athleteWallet);
        FHE.allowThis(_totalAthleteEarningsUSD);
        emit PerformanceBonusPaid(athleteId, block.timestamp);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub162 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub162, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function allowSponsorStats(address viewer) external onlyOwner {
        FHE.allow(_totalSponsorshipRevenueUSD, viewer); FHE.allow(_totalAthleteEarningsUSD, viewer);
    }
}
