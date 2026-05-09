// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedPrivateSurvey_b7_010 - Anonymous encrypted survey response collector
contract MixedPrivateSurvey_b7_010 is ZamaEthereumConfig {
    address public surveyCreator;
    bool public surveyOpen;

    struct Question {
        string text;
        euint32 sumResponses;
        uint256 responseCount;
        uint8 maxValue; // max answer value (e.g. 1-5 scale)
    }

    Question[] public questions;
    mapping(address => bool) public hasResponded;
    mapping(address => bool) public isEligible;

    modifier onlyCreator() {
        require(msg.sender == surveyCreator, "Not creator");
        _;
    }

    constructor() {
        surveyCreator = msg.sender;
    }

    function addQuestion(string calldata text, uint8 maxValue) public onlyCreator {
        questions.push(Question({ text: text, sumResponses: FHE.asEuint32(0), responseCount: 0, maxValue: maxValue }));
        FHE.allowThis(questions[questions.length - 1].sumResponses);
    }

    function openSurvey() public onlyCreator { surveyOpen = true; }
    function closeSurvey() public onlyCreator { surveyOpen = false; }

    function addEligible(address participant) public onlyCreator {
        isEligible[participant] = true;
    }

    function respond(uint256[] calldata answers, externalEuint8[] calldata encAnswers, bytes[] calldata proofs) public {
        require(surveyOpen, "Survey closed");
        require(isEligible[msg.sender], "Not eligible");
        require(!hasResponded[msg.sender], "Already responded");
        require(answers.length == questions.length, "Wrong answer count");
        require(encAnswers.length == questions.length, "Wrong encrypted count");

        hasResponded[msg.sender] = true;
        for (uint256 i = 0; i < questions.length; i++) {
            // Use encrypted answer for both tallying approaches
            FHE.fromExternal(encAnswers[i], proofs[i]); // store encrypted version
            questions[i].sumResponses = FHE.add(questions[i].sumResponses, FHE.asEuint32(uint32(answers[i])));
            questions[i].responseCount++;
            FHE.allowThis(questions[i].sumResponses);
        }
    }

    function allowResults(uint256 questionId, address viewer) public onlyCreator {
        FHE.allow(questions[questionId].sumResponses, viewer);
    }

    function getQuestionCount() public view returns (uint256) {
        return questions.length;
    }
}
