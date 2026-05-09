// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateEsportsPlayerTransferMarket
/// @notice Encrypted esports player transfer market: confidential player valuation, hidden
///         contract buyout clauses, private salary structures, and encrypted performance
///         KPIs used for valuation computation.
contract PrivateEsportsPlayerTransferMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum GameTitle { LeagueOfLegends, Valorant, CSGO, Dota2, Fortnite, PUBG }
    enum TransferStatus { Listed, OfferReceived, NegotiatingContract, Transferred, Withdrawn }

    struct PlayerProfile {
        address playerWallet;
        string playerTag;
        GameTitle gameTitle;
        euint64 currentSalaryUSD;      // encrypted current salary
        euint64 marketValueUSD;        // encrypted market valuation
        euint64 buyoutClauseUSD;       // encrypted release clause
        euint32 kpiRating;             // encrypted performance KPI (0-10000)
        euint16 winRateBps;            // encrypted win rate in bps
        address currentTeam;
        TransferStatus status;
    }

    struct TransferOffer {
        uint256 playerId;
        address offeringTeam;
        euint64 offerAmountUSD;        // encrypted offer amount
        euint64 proposedSalaryUSD;     // encrypted proposed salary
        euint16 contractDurationMonths;// encrypted contract duration
        uint256 offerExpiry;
        bool accepted;
    }

    mapping(uint256 => PlayerProfile) private players;
    mapping(uint256 => TransferOffer) private offers;
    mapping(address => bool) public isRegisteredTeam;
    mapping(address => bool) public isFIFALicensedAgent;

    uint256 public playerCount;
    uint256 public offerCount;
    euint64 private _totalTransferVolumeUSD;
    euint64 private _totalAgentFeesUSD;

    event PlayerListed(uint256 indexed playerId, GameTitle gameTitle);
    event OfferSubmitted(uint256 indexed offerId, uint256 playerId);
    event TransferCompleted(uint256 indexed playerId, address newTeam);

    modifier onlyRegisteredTeam() {
        require(isRegisteredTeam[msg.sender] || msg.sender == owner(), "Not registered team");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTransferVolumeUSD = FHE.asEuint64(0);
        _totalAgentFeesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalTransferVolumeUSD);
        FHE.allowThis(_totalAgentFeesUSD);
        isRegisteredTeam[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function registerTeam(address t) external onlyOwner { isRegisteredTeam[t] = true; }
    function registerAgent(address a) external onlyOwner { isFIFALicensedAgent[a] = true; }

    function listPlayer(
        address playerWallet,
        string calldata playerTag,
        GameTitle gameTitle,
        externalEuint64 encSalary, bytes calldata salProof,
        externalEuint64 encValue, bytes calldata valProof,
        externalEuint64 encBuyout, bytes calldata buyProof,
        externalEuint32 encKPI, bytes calldata kpiProof,
        externalEuint16 encWinRate, bytes calldata wrProof
    ) external onlyRegisteredTeam whenNotPaused returns (uint256 id) {
        euint64 salary = FHE.fromExternal(encSalary, salProof);
        euint64 value = FHE.fromExternal(encValue, valProof);
        euint64 buyout = FHE.fromExternal(encBuyout, buyProof);
        euint32 kpi = FHE.fromExternal(encKPI, kpiProof);
        euint16 winRate = FHE.fromExternal(encWinRate, wrProof);
        id = playerCount++;
        players[id].playerWallet = playerWallet;
        players[id].playerTag = playerTag;
        players[id].gameTitle = gameTitle;
        players[id].currentSalaryUSD = salary;
        players[id].marketValueUSD = value;
        players[id].buyoutClauseUSD = buyout;
        players[id].kpiRating = kpi;
        players[id].winRateBps = winRate;
        players[id].currentTeam = msg.sender;
        players[id].status = TransferStatus.Listed;
        FHE.allowThis(players[id].currentSalaryUSD); FHE.allow(players[id].currentSalaryUSD, playerWallet); FHE.allow(players[id].currentSalaryUSD, msg.sender);
        FHE.allowThis(players[id].marketValueUSD); FHE.allow(players[id].marketValueUSD, msg.sender);
        FHE.allowThis(players[id].buyoutClauseUSD);
        FHE.allowThis(players[id].kpiRating); FHE.allow(players[id].kpiRating, playerWallet);
        FHE.allowThis(players[id].winRateBps); FHE.allow(players[id].winRateBps, playerWallet);
        emit PlayerListed(id, gameTitle);
    }

    function submitOffer(
        uint256 playerId,
        externalEuint64 encOfferAmt, bytes calldata oaProof,
        externalEuint64 encPropSalary, bytes calldata psProof,
        externalEuint16 encContractDur, bytes calldata cdProof,
        uint256 expiryDays
    ) external onlyRegisteredTeam whenNotPaused returns (uint256 offerId) {
        PlayerProfile storage p = players[playerId];
        require(p.status == TransferStatus.Listed, "Not listed");
        euint64 offerAmt = FHE.fromExternal(encOfferAmt, oaProof);
        euint64 propSalary = FHE.fromExternal(encPropSalary, psProof);
        euint16 contractDur = FHE.fromExternal(encContractDur, cdProof);
        offerId = offerCount++;
        offers[offerId] = TransferOffer({
            playerId: playerId, offeringTeam: msg.sender, offerAmountUSD: offerAmt,
            proposedSalaryUSD: propSalary, contractDurationMonths: contractDur,
            offerExpiry: block.timestamp + expiryDays * 1 days, accepted: false
        });
        p.status = TransferStatus.OfferReceived;
        FHE.allowThis(offers[offerId].offerAmountUSD); FHE.allow(offers[offerId].offerAmountUSD, p.currentTeam); FHE.allow(offers[offerId].offerAmountUSD, p.playerWallet);
        FHE.allowThis(offers[offerId].proposedSalaryUSD); FHE.allow(offers[offerId].proposedSalaryUSD, p.playerWallet);
        FHE.allowThis(offers[offerId].contractDurationMonths); FHE.allow(offers[offerId].contractDurationMonths, p.playerWallet);
        emit OfferSubmitted(offerId, playerId);
    }

    function acceptOffer(uint256 offerId) external nonReentrant {
        TransferOffer storage o = offers[offerId];
        PlayerProfile storage p = players[o.playerId];
        require(msg.sender == p.currentTeam || msg.sender == p.playerWallet, "Not authorized");
        require(!o.accepted && block.timestamp < o.offerExpiry, "Offer invalid");
        o.accepted = true;
        p.status = TransferStatus.Transferred;
        // Agent fee: 5% of transfer fee (plaintext divisor)
        euint64 agentFee = FHE.div(o.offerAmountUSD, 20);
        _totalTransferVolumeUSD = FHE.add(_totalTransferVolumeUSD, o.offerAmountUSD);
        _totalAgentFeesUSD = FHE.add(_totalAgentFeesUSD, agentFee);
        p.currentTeam = o.offeringTeam;
        FHE.allowThis(_totalTransferVolumeUSD);
        FHE.allowThis(_totalAgentFeesUSD);
        emit TransferCompleted(o.playerId, o.offeringTeam);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalTransferVolumeUSD, viewer);
        FHE.allow(_totalAgentFeesUSD, viewer);
    }
}
