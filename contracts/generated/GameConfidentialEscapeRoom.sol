// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameConfidentialEscapeRoom
/// @notice On-chain escape room with encrypted puzzle keys. Players solve puzzles
///         by submitting encrypted answers; correct solutions unlock next puzzle.
///         Completion time and hint usage are tracked privately.
contract GameConfidentialEscapeRoom is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Puzzle {
        string hint;        // public hint
        euint32 answer;     // encrypted correct answer
        euint64 reward;     // encrypted reward for solving
        bool active;
    }

    struct PlayerProgress {
        uint256 currentPuzzle;
        euint8 hintsUsed;
        euint64 totalReward;
        uint256 startTime;
        uint256 completionTime;
        bool completed;
    }

    mapping(uint256 => Puzzle) private puzzles;
    uint256 public puzzleCount;
    mapping(address => PlayerProgress) private playerProgress;
    euint64 private _hintPenaltyBps; // penalty to reward for using hints
    euint64 private _completionBonus;

    event PuzzleAdded(uint256 indexed id);
    event PuzzleSolved(address indexed player, uint256 puzzleId);
    event EscapeCompleted(address indexed player);
    event HintUsed(address indexed player, uint256 puzzleId);

    constructor(
        externalEuint64 encHintPenalty, bytes memory hProof,
        externalEuint64 encBonus, bytes memory bProof
    ) Ownable(msg.sender) {
        _hintPenaltyBps = FHE.fromExternal(encHintPenalty, hProof);
        _completionBonus = FHE.fromExternal(encBonus, bProof);
        FHE.allowThis(_hintPenaltyBps);
        FHE.allowThis(_completionBonus);
    }

    function addPuzzle(
        string calldata hint,
        externalEuint32 encAnswer, bytes calldata aProof,
        externalEuint64 encReward, bytes calldata rProof
    ) external onlyOwner returns (uint256 id) {
        id = puzzleCount++;
        puzzles[id].hint = hint;
        puzzles[id].answer = FHE.fromExternal(encAnswer, aProof);
        puzzles[id].reward = FHE.fromExternal(encReward, rProof);
        puzzles[id].active = true;
        FHE.allowThis(puzzles[id].answer);
        FHE.allowThis(puzzles[id].reward);
        emit PuzzleAdded(id);
    }

    function startGame() external {
        require(playerProgress[msg.sender].startTime == 0, "Already started");
        playerProgress[msg.sender].currentPuzzle = 0;
        playerProgress[msg.sender].hintsUsed = FHE.asEuint8(0);
        playerProgress[msg.sender].totalReward = FHE.asEuint64(0);
        playerProgress[msg.sender].startTime = block.timestamp;
        FHE.allowThis(playerProgress[msg.sender].hintsUsed);
        FHE.allowThis(playerProgress[msg.sender].totalReward);
        FHE.allow(playerProgress[msg.sender].totalReward, msg.sender);
    }

    function submitAnswer(externalEuint32 encAnswer, bytes calldata proof) external nonReentrant {
        PlayerProgress storage pp = playerProgress[msg.sender];
        require(pp.startTime > 0 && !pp.completed, "Cannot submit");
        uint256 puzzleId = pp.currentPuzzle;
        require(puzzleId < puzzleCount, "All solved");
        euint32 answer = FHE.fromExternal(encAnswer, proof);
        ebool correct = FHE.eq(answer, puzzles[puzzleId].answer);
        if (FHE.isInitialized(correct)) {
            pp.totalReward = FHE.add(pp.totalReward, puzzles[puzzleId].reward);
            pp.currentPuzzle++;
            FHE.allowThis(pp.totalReward);
            FHE.allow(pp.totalReward, msg.sender);
            emit PuzzleSolved(msg.sender, puzzleId);
            if (pp.currentPuzzle >= puzzleCount) {
                pp.completed = true;
                pp.completionTime = block.timestamp;
                pp.totalReward = FHE.add(pp.totalReward, _completionBonus);
                FHE.allowThis(pp.totalReward);
                FHE.allow(pp.totalReward, msg.sender);
                emit EscapeCompleted(msg.sender);
            }
        }
    }

    function useHint(uint256 puzzleId) external {
        PlayerProgress storage pp = playerProgress[msg.sender];
        require(pp.startTime > 0 && !pp.completed, "Cannot use hint");
        pp.hintsUsed = FHE.add(pp.hintsUsed, FHE.asEuint8(1));
        // Apply hint penalty: reduce total reward by penalty %
        euint64 penalty = FHE.div(FHE.mul(pp.totalReward, _hintPenaltyBps), 10000);
        pp.totalReward = FHE.sub(pp.totalReward, penalty);
        FHE.allowThis(pp.hintsUsed);
        FHE.allowThis(pp.totalReward);
        FHE.allow(pp.totalReward, msg.sender);
        emit HintUsed(msg.sender, puzzleId);
    }

    function claimReward() external {
        PlayerProgress storage pp = playerProgress[msg.sender];
        require(pp.completed, "Not completed");
        FHE.allow(pp.totalReward, msg.sender);
    }
}
