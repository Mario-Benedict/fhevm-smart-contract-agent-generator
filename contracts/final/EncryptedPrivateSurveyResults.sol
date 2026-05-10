// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateSurveyResults
/// @notice Encrypted survey platform: hidden individual responses, private aggregate
///         statistics, confidential demographic breakdowns, and encrypted reward
///         distribution to survey participants.
contract EncryptedPrivateSurveyResults is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Survey {
        address creator;
        string title;
        string surveyRef;
        uint8  questionCount;
        euint64 rewardPerResponseUSD;  // encrypted reward
        euint64 totalBudgetUSD;        // encrypted total budget
        euint64 spentBudgetUSD;        // encrypted spent
        euint32 responseCount;         // encrypted response count
        euint64 aggregateScoreSum;     // encrypted sum of scores
        uint256 deadline;
        bool active;
    }

    struct SurveyResponse {
        address respondent;
        uint256 surveyId;
        euint8  q1Response;            // encrypted Q1 answer
        euint8  q2Response;            // encrypted Q2 answer
        euint8  q3Response;            // encrypted Q3 answer
        euint8  q4Response;            // encrypted Q4 answer
        euint16 netPromoterScore;      // encrypted NPS
        euint64 rewardEarned;          // encrypted reward
        uint256 submittedAt;
    }

    mapping(uint256 => Survey) private surveys;
    mapping(uint256 => SurveyResponse) private responses;
    mapping(uint256 => mapping(address => bool)) public hasResponded;
    mapping(address => bool) public isSurveyAdmin;

    uint256 public surveyCount;
    uint256 public responseCount;
    euint64 private _totalRewardsDistributed;

    event SurveyCreated(uint256 indexed id, string title);
    event ResponseSubmitted(uint256 indexed responseId, uint256 surveyId);

    modifier onlySurveyAdmin() {
        require(isSurveyAdmin[msg.sender] || msg.sender == owner(), "Not survey admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRewardsDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalRewardsDistributed);
        isSurveyAdmin[msg.sender] = true;
    }

    function addSurveyAdmin(address sa) external onlyOwner { isSurveyAdmin[sa] = true; }

    function createSurvey(
        string calldata title, string calldata surveyRef, uint8 questionCount,
        externalEuint64 encReward, bytes calldata rProof,
        externalEuint64 encBudget, bytes calldata bProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 reward = FHE.fromExternal(encReward, rProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        id = surveyCount++;
        surveys[id].creator = msg.sender;
        surveys[id].title = title;
        surveys[id].surveyRef = surveyRef;
        surveys[id].questionCount = questionCount;
        surveys[id].rewardPerResponseUSD = reward;
        surveys[id].totalBudgetUSD = budget;
        surveys[id].spentBudgetUSD = FHE.asEuint64(0);
        surveys[id].responseCount = FHE.asEuint32(0);
        surveys[id].aggregateScoreSum = FHE.asEuint64(0);
        surveys[id].deadline = block.timestamp + durationDays * 1 days;
        surveys[id].active = true;
        FHE.allowThis(surveys[id].rewardPerResponseUSD); FHE.allow(surveys[id].rewardPerResponseUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRewardsDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(surveys[id].totalBudgetUSD); FHE.allow(surveys[id].totalBudgetUSD, msg.sender);
        FHE.allowThis(surveys[id].spentBudgetUSD); FHE.allow(surveys[id].spentBudgetUSD, msg.sender);
        FHE.allowThis(surveys[id].responseCount); FHE.allow(surveys[id].responseCount, msg.sender);
        FHE.allowThis(surveys[id].aggregateScoreSum); FHE.allow(surveys[id].aggregateScoreSum, msg.sender);
        emit SurveyCreated(id, title);
    }

    function submitResponse(
        uint256 surveyId,
        externalEuint8  encQ1, bytes calldata q1Proof,
        externalEuint8  encQ2, bytes calldata q2Proof,
        externalEuint8  encQ3, bytes calldata q3Proof,
        externalEuint8  encQ4, bytes calldata q4Proof,
        externalEuint16 encNPS, bytes calldata npsProof
    ) external nonReentrant returns (uint256 respId) {
        Survey storage s = surveys[surveyId];
        require(s.active && block.timestamp < s.deadline && !hasResponded[surveyId][msg.sender], "Cannot respond");
        euint8  q1  = FHE.fromExternal(encQ1, q1Proof);
        euint8  q2  = FHE.fromExternal(encQ2, q2Proof);
        euint8  q3  = FHE.fromExternal(encQ3, q3Proof);
        euint8  q4  = FHE.fromExternal(encQ4, q4Proof);
        euint16 nps = FHE.fromExternal(encNPS, npsProof);
        ebool budgetAvail = FHE.gt(FHE.sub(s.totalBudgetUSD, s.spentBudgetUSD), s.rewardPerResponseUSD);
        euint64 reward = FHE.select(budgetAvail, s.rewardPerResponseUSD, FHE.asEuint64(0));
        respId = responseCount++;
        responses[respId].respondent = msg.sender;
        responses[respId].surveyId = surveyId;
        responses[respId].q1Response = q1;
        responses[respId].q2Response = q2;
        responses[respId].q3Response = q3;
        responses[respId].q4Response = q4;
        responses[respId].netPromoterScore = nps;
        responses[respId].rewardEarned = reward;
        responses[respId].submittedAt = block.timestamp;
        hasResponded[surveyId][msg.sender] = true;
        s.responseCount = FHE.add(s.responseCount, FHE.asEuint32(1));
        s.spentBudgetUSD = FHE.add(s.spentBudgetUSD, reward);
        s.aggregateScoreSum = FHE.add(s.aggregateScoreSum, FHE.asEuint64(1));
        _totalRewardsDistributed = FHE.add(_totalRewardsDistributed, reward);
        FHE.allowThis(responses[respId].q1Response); FHE.allowThis(responses[respId].q2Response);
        FHE.allowThis(responses[respId].q3Response); FHE.allowThis(responses[respId].q4Response);
        FHE.allowThis(responses[respId].netPromoterScore); FHE.allow(responses[respId].netPromoterScore, msg.sender);
        FHE.allowThis(responses[respId].rewardEarned); FHE.allow(responses[respId].rewardEarned, msg.sender);
        FHE.allowThis(s.responseCount); FHE.allow(s.responseCount, s.creator);
        FHE.allowThis(s.spentBudgetUSD); FHE.allow(s.spentBudgetUSD, s.creator);
        FHE.allowThis(s.aggregateScoreSum); FHE.allow(s.aggregateScoreSum, s.creator);
        FHE.allowThis(_totalRewardsDistributed);
        emit ResponseSubmitted(respId, surveyId);
    }

    function allowPlatformStats(address viewer) external onlyOwner { FHE.allow(_totalRewardsDistributed, viewer); }
    function getSurveyResponseCount(uint256 id) external view returns (euint32) { return surveys[id].responseCount; }
    function getAggregateScore(uint256 id) external view returns (euint64) { return surveys[id].aggregateScoreSum; }
}
