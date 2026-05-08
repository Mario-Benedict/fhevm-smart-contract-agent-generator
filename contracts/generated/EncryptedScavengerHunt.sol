// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedScavengerHunt - On-chain puzzle hunt with encrypted clue answers and prize
contract EncryptedScavengerHunt is ZamaEthereumConfig, Ownable {
    struct Clue {
        string hint;
        euint32 answerHash; // FHE-encrypted hash of correct answer
        euint64 reward;
        bool solved;
        address solver;
    }

    mapping(uint256 => Clue) public clues;
    mapping(address => euint64) public participantScore;
    mapping(address => bool) public registered;
    uint256 public clueCount;
    uint256 public huntEndTime;

    event HuntStarted(uint256 endTime);
    event ClueAdded(uint256 indexed clueId, string hint);
    event ClueSolved(uint256 indexed clueId, address indexed solver);
    event ScoreClaimed(address indexed participant);

    constructor() Ownable(msg.sender) {}

    function startHunt(uint256 duration) external onlyOwner {
        huntEndTime = block.timestamp + duration;
        emit HuntStarted(huntEndTime);
    }

    function addClue(
        string calldata hint,
        externalEuint32 calldata encAnswerHash,
        bytes calldata inputProof,
        externalEuint64 calldata encReward,
        bytes calldata rewardProof
    ) external onlyOwner returns (uint256 clueId) {
        clueId = clueCount++;
        Clue storage c = clues[clueId];
        c.hint = hint;
        c.answerHash = FHE.fromExternal(encAnswerHash, inputProof);
        c.reward = FHE.fromExternal(encReward, rewardProof);
        FHE.allowThis(c.answerHash);
        FHE.allowThis(c.reward);
        emit ClueAdded(clueId, hint);
    }

    function register() external {
        require(!registered[msg.sender], "Already registered");
        registered[msg.sender] = true;
        participantScore[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(participantScore[msg.sender]);
        FHE.allow(participantScore[msg.sender], msg.sender);
    }

    function submitAnswer(uint256 clueId, externalEuint32 calldata encAnswer, bytes calldata inputProof) external {
        require(registered[msg.sender], "Not registered");
        require(block.timestamp <= huntEndTime, "Hunt ended");
        Clue storage c = clues[clueId];
        require(!c.solved, "Already solved");

        euint32 answer = FHE.fromExternal(encAnswer, inputProof);
        ebool correct = FHE.eq(answer, c.answerHash);
        euint64 earnedReward = FHE.select(correct, c.reward, FHE.asEuint64(0));

        participantScore[msg.sender] = FHE.add(participantScore[msg.sender], earnedReward);
        FHE.allowThis(participantScore[msg.sender]);
        FHE.allow(participantScore[msg.sender], msg.sender);

        if (correct.unwrap() != 0) {
            c.solved = true;
            c.solver = msg.sender;
            emit ClueSolved(clueId, msg.sender);
        }
    }

    function getScore() external view returns (euint64) {
        return participantScore[msg.sender];
    }
}
