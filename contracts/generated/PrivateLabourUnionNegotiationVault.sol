// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateLabourUnionNegotiationVault
/// @notice Labour collective bargaining system with encrypted wage demands,
///         management counter-offers, vote tallies, and strike fund balances.
contract PrivateLabourUnionNegotiationVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum NegotiationStatus { OPEN, MEDIATION, ARBITRATION, RATIFIED, FAILED, STRIKE }
    enum ProposalType { WAGE_INCREASE, BENEFITS, HOURS, SAFETY, REDUNDANCY, BONUS }

    struct NegotiationSession {
        string unionName;
        string employerName;
        address unionLead;
        address employerRep;
        NegotiationStatus status;
        euint64 currentBaseWage;      // encrypted current average wage
        euint64 unionWageDemand;      // encrypted union's ask
        euint64 employerWageOffer;    // encrypted employer's counter
        euint64 mediatedSettlement;   // encrypted final agreed wage
        euint32 unionMemberCount;     // encrypted membership
        euint32 votesForRatification; // encrypted yes votes
        euint32 votesAgainst;         // encrypted no votes
        euint64 strikeFundBalance;    // encrypted strike reserve
        uint256 sessionStart;
        uint256 deadline;
        bool ratified;
    }

    struct MemberVote {
        uint256 sessionId;
        euint8  satisfactionScore;    // encrypted 0-100 member satisfaction
        bool votedYes;
        bool hasVoted;
    }

    mapping(uint256 => NegotiationSession) private sessions;
    mapping(address => mapping(uint256 => MemberVote)) private memberVotes;
    mapping(address => bool) public isUnionDelegate;
    mapping(address => bool) public isMediator;
    uint256 public sessionCount;
    euint64 private _totalStrikeFunds;
    euint64 private _totalWageGainsAchieved;

    event SessionCreated(uint256 indexed sessionId, string union, string employer);
    event ProposalSubmitted(uint256 indexed sessionId, ProposalType pType);
    event MemberVoteCast(uint256 indexed sessionId, address member);
    event SessionRatified(uint256 indexed sessionId);
    event StrikeTriggered(uint256 indexed sessionId);
    event StrikeFundDeposited(uint256 indexed sessionId);

    constructor() Ownable(msg.sender) {
        _totalStrikeFunds = FHE.asEuint64(0);
        _totalWageGainsAchieved = FHE.asEuint64(0);
        FHE.allowThis(_totalStrikeFunds);
        FHE.allowThis(_totalWageGainsAchieved);
        isUnionDelegate[msg.sender] = true;
        isMediator[msg.sender] = true;
    }

    function addDelegate(address d) external onlyOwner { isUnionDelegate[d] = true; }
    function addMediator(address m) external onlyOwner { isMediator[m] = true; }

    function openNegotiation(
        string calldata unionName,
        string calldata employerName,
        address employerRep,
        externalEuint64 encCurrentWage, bytes calldata cwProof,
        externalEuint64 encDemand,      bytes calldata dProof,
        externalEuint32 encMembers,     bytes calldata mProof,
        externalEuint64 encStrikeFund,  bytes calldata sfProof,
        uint256 deadline
    ) external returns (uint256 sessionId) {
        require(isUnionDelegate[msg.sender], "Not delegate");
        euint64 curWage    = FHE.fromExternal(encCurrentWage, cwProof);
        euint64 demand     = FHE.fromExternal(encDemand, dProof);
        euint32 members    = FHE.fromExternal(encMembers, mProof);
        euint64 strikeFund = FHE.fromExternal(encStrikeFund, sfProof);
        sessionId = sessionCount++;
        sessions[sessionId] = NegotiationSession({
            unionName: unionName, employerName: employerName,
            unionLead: msg.sender, employerRep: employerRep,
            status: NegotiationStatus.OPEN,
            currentBaseWage: curWage, unionWageDemand: demand,
            employerWageOffer: FHE.asEuint64(0), mediatedSettlement: FHE.asEuint64(0),
            unionMemberCount: members, votesForRatification: FHE.asEuint32(0),
            votesAgainst: FHE.asEuint32(0), strikeFundBalance: strikeFund,
            sessionStart: block.timestamp, deadline: deadline, ratified: false
        });
        _totalStrikeFunds = FHE.add(_totalStrikeFunds, strikeFund);
        FHE.allowThis(sessions[sessionId].currentBaseWage);
        FHE.allowThis(sessions[sessionId].unionWageDemand);
        FHE.allow(sessions[sessionId].unionWageDemand, msg.sender);
        FHE.allowThis(sessions[sessionId].employerWageOffer);
        FHE.allow(sessions[sessionId].employerWageOffer, employerRep);
        FHE.allowThis(sessions[sessionId].mediatedSettlement);
        FHE.allowThis(sessions[sessionId].unionMemberCount);
        FHE.allowThis(sessions[sessionId].votesForRatification);
        FHE.allowThis(sessions[sessionId].votesAgainst);
        FHE.allowThis(sessions[sessionId].strikeFundBalance);
        FHE.allow(sessions[sessionId].strikeFundBalance, msg.sender);
        FHE.allowThis(_totalStrikeFunds);
        emit SessionCreated(sessionId, unionName, employerName);
    }

    function submitEmployerOffer(
        uint256 sessionId,
        externalEuint64 encOffer, bytes calldata proof
    ) external {
        require(sessions[sessionId].employerRep == msg.sender, "Not employer rep");
        euint64 offer = FHE.fromExternal(encOffer, proof);
        sessions[sessionId].employerWageOffer = offer;
        FHE.allowThis(sessions[sessionId].employerWageOffer);
        FHE.allow(sessions[sessionId].employerWageOffer, sessions[sessionId].unionLead);
        emit ProposalSubmitted(sessionId, ProposalType.WAGE_INCREASE);
    }

    function mediateSettlement(
        uint256 sessionId,
        externalEuint64 encSettlement, bytes calldata proof
    ) external {
        require(isMediator[msg.sender], "Not mediator");
        euint64 settlement = FHE.fromExternal(encSettlement, proof);
        sessions[sessionId].mediatedSettlement = settlement;
        sessions[sessionId].status = NegotiationStatus.MEDIATION;
        FHE.allowThis(sessions[sessionId].mediatedSettlement);
        FHE.allow(sessions[sessionId].mediatedSettlement, sessions[sessionId].unionLead);
        FHE.allow(sessions[sessionId].mediatedSettlement, sessions[sessionId].employerRep);
    }

    function castMemberVote(uint256 sessionId, bool voteYes, externalEuint8 encSatisfaction, bytes calldata proof) external {
        require(!memberVotes[msg.sender][sessionId].hasVoted, "Already voted");
        euint8 satisfaction = FHE.fromExternal(encSatisfaction, proof);
        memberVotes[msg.sender][sessionId] = MemberVote({
            sessionId: sessionId,
            satisfactionScore: satisfaction,
            votedYes: voteYes,
            hasVoted: true
        });
        FHE.allowThis(memberVotes[msg.sender][sessionId].satisfactionScore);
        if (voteYes) {
            sessions[sessionId].votesForRatification = FHE.add(sessions[sessionId].votesForRatification, FHE.asEuint32(1));
            FHE.allowThis(sessions[sessionId].votesForRatification);
        } else {
            sessions[sessionId].votesAgainst = FHE.add(sessions[sessionId].votesAgainst, FHE.asEuint32(1));
            FHE.allowThis(sessions[sessionId].votesAgainst);
        }
        emit MemberVoteCast(sessionId, msg.sender);
    }

    function ratifyAgreement(uint256 sessionId) external {
        require(isUnionDelegate[msg.sender], "Not delegate");
        sessions[sessionId].ratified = true;
        sessions[sessionId].status = NegotiationStatus.RATIFIED;
        euint64 gain = FHE.sub(sessions[sessionId].mediatedSettlement, sessions[sessionId].currentBaseWage);
        _totalWageGainsAchieved = FHE.add(_totalWageGainsAchieved, gain);
        FHE.allowThis(_totalWageGainsAchieved);
        emit SessionRatified(sessionId);
    }

    function triggerStrike(uint256 sessionId) external {
        require(isUnionDelegate[msg.sender], "Not delegate");
        sessions[sessionId].status = NegotiationStatus.STRIKE;
        emit StrikeTriggered(sessionId);
    }

    function allowNegotiationView(uint256 sessionId, address viewer) external {
        require(isMediator[msg.sender], "Not mediator");
        FHE.allow(sessions[sessionId].unionWageDemand, viewer);
        FHE.allow(sessions[sessionId].employerWageOffer, viewer);
        FHE.allow(sessions[sessionId].mediatedSettlement, viewer);
    }
}
