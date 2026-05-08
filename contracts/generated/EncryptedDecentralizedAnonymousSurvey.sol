// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDecentralizedAnonymousSurvey
/// @notice On-chain anonymous survey where each respondent's answers are
///         encrypted. Aggregate statistics computed via FHE without
///         revealing individual responses.
contract EncryptedDecentralizedAnonymousSurvey is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    uint8 public constant MAX_QUESTIONS = 20;
    uint8 public constant MAX_OPTIONS = 10;

    struct Survey {
        string title;
        uint8 questionCount;
        uint256 closingTime;
        bool finalized;
        mapping(uint8 => string) questions;
        mapping(uint8 => uint8) optionCount;
        // Aggregate encrypted vote counts per question per option
        mapping(uint8 => mapping(uint8 => euint32)) optionTally;
        mapping(address => bool) responded;
        uint256 responseCount;
    }

    uint256 public nextSurveyId;
    mapping(uint256 => Survey) private surveys;

    event SurveyCreated(uint256 indexed surveyId, string title, uint256 closingTime);
    event ResponseSubmitted(uint256 indexed surveyId, uint256 responseCount);
    event SurveyFinalized(uint256 indexed surveyId);

    constructor() Ownable(msg.sender) {}

    function createSurvey(
        string calldata title,
        string[] calldata questions,
        uint8[] calldata optionCounts,
        uint256 closingTime
    ) external onlyOwner returns (uint256 surveyId) {
        require(questions.length == optionCounts.length, "Mismatch");
        require(questions.length <= MAX_QUESTIONS, "Too many questions");
        surveyId = nextSurveyId++;
        Survey storage s = surveys[surveyId];
        s.title = title;
        s.questionCount = uint8(questions.length);
        s.closingTime = closingTime;
        s.finalized = false;

        for (uint8 i = 0; i < questions.length; i++) {
            s.questions[i] = questions[i];
            s.optionCount[i] = optionCounts[i];
            for (uint8 j = 0; j < optionCounts[i]; j++) {
                s.optionTally[i][j] = FHE.asEuint32(0);
                FHE.allowThis(s.optionTally[i][j]);
            }
        }
        emit SurveyCreated(surveyId, title, closingTime);
    }

    /// @notice Submit encrypted responses (one externalEuint8 per question indicating chosen option)
    function submitResponse(
        uint256 surveyId,
        externalEuint8[] calldata encChoices,
        bytes[] calldata proofs
    ) external nonReentrant {
        Survey storage s = surveys[surveyId];
        require(block.timestamp < s.closingTime, "Survey closed");
        require(!s.responded[msg.sender], "Already responded");
        require(!s.finalized, "Finalized");
        require(encChoices.length == s.questionCount, "Wrong count");

        s.responded[msg.sender] = true;
        s.responseCount++;

        for (uint8 i = 0; i < s.questionCount; i++) {
            euint8 choice = FHE.fromExternal(encChoices[i], proofs[i]);
            uint8 opts = s.optionCount[i];
            // Increment tally for the chosen option using FHE.select
            for (uint8 j = 0; j < opts; j++) {
                ebool selected = FHE.eq(choice, FHE.asEuint8(j));
                euint32 increment = FHE.select(selected, FHE.asEuint32(1), FHE.asEuint32(0));
                s.optionTally[i][j] = FHE.add(s.optionTally[i][j], increment);
                FHE.allowThis(s.optionTally[i][j]);
            }
        }
        emit ResponseSubmitted(surveyId, s.responseCount);
    }

    function finalizeSurvey(uint256 surveyId) external onlyOwner {
        Survey storage s = surveys[surveyId];
        require(block.timestamp >= s.closingTime, "Not closed yet");
        require(!s.finalized, "Already finalized");
        s.finalized = true;

        // Grant owner read access to all tallies
        for (uint8 i = 0; i < s.questionCount; i++) {
            for (uint8 j = 0; j < s.optionCount[i]; j++) {
                FHE.allow(s.optionTally[i][j], owner());
            }
        }
        emit SurveyFinalized(surveyId);
    }

    function allowTallyView(uint256 surveyId, address viewer) external onlyOwner {
        Survey storage s = surveys[surveyId];
        for (uint8 i = 0; i < s.questionCount; i++) {
            for (uint8 j = 0; j < s.optionCount[i]; j++) {
                FHE.allow(s.optionTally[i][j], viewer);
            }
        }
    }

    function getSurveyMeta(uint256 surveyId) external view returns (
        string memory title, uint8 questionCount, uint256 closingTime, bool finalized, uint256 responseCount
    ) {
        Survey storage s = surveys[surveyId];
        return (s.title, s.questionCount, s.closingTime, s.finalized, s.responseCount);
    }
}
