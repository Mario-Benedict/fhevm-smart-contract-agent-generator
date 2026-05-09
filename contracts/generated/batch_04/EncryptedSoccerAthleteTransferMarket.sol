// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsAthleteTransferFee
/// @notice Football/soccer transfer market where player valuation, agent fees,
///         signing bonuses, performance add-ons, and sell-on clauses
///         are kept encrypted between clubs and agents.
contract EncryptedSportsAthleteTransferFee is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TransferType { PERMANENT, LOAN, LOAN_TO_BUY, FREE_TRANSFER, SWAP }
    enum PlayerPosition { GOALKEEPER, DEFENDER, MIDFIELDER, FORWARD }

    struct PlayerContract {
        string playerName;
        string nationality;
        uint256 dateOfBirth;
        PlayerPosition position;
        address currentClub;
        euint64 marketValueEUR;       // encrypted FIFA valuation
        euint64 weeklySalaryEUR;      // encrypted current wage
        euint64 releaseClauses;       // encrypted release clause
        euint32 contractEndYear;      // encrypted contract expiry
        euint8  performanceRating;    // encrypted 0-100 season rating
        euint8  injuryHistory;        // encrypted injury risk 0-10
        bool transferListed;
        bool onLoan;
    }

    struct TransferDeal {
        uint256 playerId;
        address sellingClub;
        address buyingClub;
        address playerAgent;
        TransferType transferType;
        euint64 transferFeeEUR;       // encrypted base transfer fee
        euint64 agentFeeEUR;          // encrypted agent/intermediary commission
        euint64 signingBonusEUR;      // encrypted player signing bonus
        euint64 performanceAddons;    // encrypted conditional add-ons total
        euint64 sellOnClausePct;      // encrypted sell-on % (bps)
        euint64 loanFeeMonthlyEUR;    // encrypted loan rental if applicable
        uint256 dealDate;
        uint256 loanEndDate;
        bool dealSigned;
        bool paymentComplete;
    }

    struct ClubFinancials {
        euint64 transferBudgetEUR;    // encrypted remaining transfer budget
        euint64 wageBillMonthlyEUR;   // encrypted monthly wage total
        euint64 netSpendEUR;          // encrypted net transfer spend (season)
        euint64 squadValueEUR;        // encrypted total squad market value
        euint32 squadSize;            // encrypted squad count
        bool ffpCompliant;
    }

    mapping(uint256 => PlayerContract) private players;
    mapping(uint256 => TransferDeal) private deals;
    mapping(address => ClubFinancials) private clubs;
    mapping(address => bool) public isLicensedAgent;
    mapping(address => bool) public isFIFAOfficial;
    uint256 public playerCount;
    uint256 public dealCount;
    euint64 private _globalTransferMarketVolume;
    euint64 private _seasonNetSpend;

    event PlayerRegistered(uint256 indexed playerId, string name);
    event TransferNegotiated(uint256 indexed dealId, uint256 playerId);
    event DealSigned(uint256 indexed dealId);
    event TransferPaymentMade(uint256 indexed dealId);
    event AgentLicensed(address indexed agent);

    constructor() Ownable(msg.sender) {
        _globalTransferMarketVolume = FHE.asEuint64(0);
        _seasonNetSpend = FHE.asEuint64(0);
        FHE.allowThis(_globalTransferMarketVolume);
        FHE.allowThis(_seasonNetSpend);
        isFIFAOfficial[msg.sender] = true;
    }

    function licenseAgent(address agent) external {
        require(isFIFAOfficial[msg.sender], "Not FIFA official");
        isLicensedAgent[agent] = true;
        emit AgentLicensed(agent);
    }

    function addFIFAOfficial(address official) external onlyOwner { isFIFAOfficial[official] = true; }

    function registerPlayer(
        string calldata name,
        string calldata nationality,
        uint256 dob,
        PlayerPosition position,
        address currentClub,
        externalEuint64 encValue,   bytes calldata vProof,
        externalEuint64 encSalary,  bytes calldata sProof,
        externalEuint64 encRelease, bytes calldata relProof,
        externalEuint32 encContractEnd, bytes calldata ceProof,
        externalEuint8  encRating,  bytes calldata rProof
    ) external returns (uint256 playerId) {
        require(isFIFAOfficial[msg.sender], "Not official");
        euint64 value   = FHE.fromExternal(encValue, vProof);
        euint64 salary  = FHE.fromExternal(encSalary, sProof);
        euint64 release = FHE.fromExternal(encRelease, relProof);
        euint32 contEnd = FHE.fromExternal(encContractEnd, ceProof);
        euint8  rating  = FHE.fromExternal(encRating, rProof);
        playerId = playerCount++;
        PlayerContract storage _s0 = players[playerId];
        _s0.playerName = name;
        _s0.nationality = nationality;
        _s0.dateOfBirth = dob;
        _s0.position = position;
        _s0.currentClub = currentClub;
        _s0.marketValueEUR = value;
        _s0.weeklySalaryEUR = salary;
        _s0.releaseClauses = release;
        _s0.contractEndYear = contEnd;
        _s0.performanceRating = rating;
        _s0.injuryHistory = FHE.asEuint8(0);
        _s0.transferListed = false;
        _s0.onLoan = false;
        FHE.allowThis(players[playerId].marketValueEUR);
        FHE.allow(players[playerId].marketValueEUR, currentClub);
        FHE.allowThis(players[playerId].weeklySalaryEUR);
        FHE.allow(players[playerId].weeklySalaryEUR, currentClub);
        FHE.allowThis(players[playerId].releaseClauses);
        FHE.allowThis(players[playerId].contractEndYear);
        FHE.allowThis(players[playerId].performanceRating);
        FHE.allowThis(players[playerId].injuryHistory);
        emit PlayerRegistered(playerId, name);
    }

    function negotiateTransfer(
        uint256 playerId,
        address buyingClub,
        address agent,
        TransferType tType,
        externalEuint64 encFee,         bytes calldata fProof,
        externalEuint64 encAgentFee,    bytes calldata afProof,
        externalEuint64 encBonus,       bytes calldata bProof,
        externalEuint64 encAddons,      bytes calldata addProof,
        externalEuint64 encSellOn,      bytes calldata soProof
    ) external returns (uint256 dealId) {
        require(isLicensedAgent[agent] || isFIFAOfficial[msg.sender], "Unauthorized");
        euint64 fee     = FHE.fromExternal(encFee, fProof);
        euint64 agentFee = FHE.fromExternal(encAgentFee, afProof);
        euint64 bonus   = FHE.fromExternal(encBonus, bProof);
        euint64 addons  = FHE.fromExternal(encAddons, addProof);
        euint64 sellOn  = FHE.fromExternal(encSellOn, soProof);
        dealId = dealCount++;
        TransferDeal storage _s1 = deals[dealId];
        _s1.playerId = playerId;
        _s1.sellingClub = players[playerId].currentClub;
        _s1.buyingClub = buyingClub;
        _s1.playerAgent = agent;
        _s1.transferType = tType;
        _s1.transferFeeEUR = fee;
        _s1.agentFeeEUR = agentFee;
        _s1.signingBonusEUR = bonus;
        _s1.performanceAddons = addons;
        _s1.sellOnClausePct = sellOn;
        _s1.loanFeeMonthlyEUR = FHE.asEuint64(0);
        _s1.dealDate = block.timestamp;
        _s1.loanEndDate = 0;
        _s1.dealSigned = false;
        _s1.paymentComplete = false;
        FHE.allowThis(deals[dealId].transferFeeEUR);
        FHE.allow(deals[dealId].transferFeeEUR, players[playerId].currentClub);
        FHE.allow(deals[dealId].transferFeeEUR, buyingClub);
        FHE.allowThis(deals[dealId].agentFeeEUR);
        FHE.allow(deals[dealId].agentFeeEUR, agent);
        FHE.allowThis(deals[dealId].signingBonusEUR);
        FHE.allowThis(deals[dealId].performanceAddons);
        FHE.allowThis(deals[dealId].sellOnClausePct);
        FHE.allow(deals[dealId].sellOnClausePct, players[playerId].currentClub);
        emit TransferNegotiated(dealId, playerId);
    }

    function signDeal(uint256 dealId) external {
        require(isFIFAOfficial[msg.sender], "Not official");
        deals[dealId].dealSigned = true;
        emit DealSigned(dealId);
    }

    function completePayment(uint256 dealId) external nonReentrant {
        require(deals[dealId].dealSigned, "Deal not signed");
        require(!deals[dealId].paymentComplete, "Already paid");
        deals[dealId].paymentComplete = true;
        // Update player's club
        players[deals[dealId].playerId].currentClub = deals[dealId].buyingClub;
        _globalTransferMarketVolume = FHE.add(_globalTransferMarketVolume, deals[dealId].transferFeeEUR);
        FHE.allowThis(_globalTransferMarketVolume);
        emit TransferPaymentMade(dealId);
    }

    function allowTransferView(uint256 dealId, address viewer) external {
        require(isFIFAOfficial[msg.sender], "Not official");
        FHE.allow(deals[dealId].transferFeeEUR, viewer);
        FHE.allow(deals[dealId].agentFeeEUR, viewer);
    }
}
