// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateWordleGame - Encrypted daily word game where guesses are compared privately
contract PrivateWordleGame is ZamaEthereumConfig, Ownable {
    struct DailyChallenge {
        euint32 secretWordHash;   // encrypted hash of the secret word
        uint256 date;
        uint32 playersAttempted;
        uint32 playersSolved;
        euint64 prizePool;
    }

    struct PlayerRound {
        uint8 attemptsUsed;
        bool solved;
        euint8 bestScore; // encrypted number of correct positions
    }

    mapping(uint256 => DailyChallenge) private challenges;
    mapping(uint256 => mapping(address => PlayerRound)) private rounds;
    mapping(address => euint64) private _playerWinnings;
    uint256 public challengeCount;
    address public wordmaster;
    uint8 public constant MAX_ATTEMPTS = 6;

    event ChallengeCreated(uint256 indexed id, uint256 date);
    event GuessSubmitted(uint256 indexed id, address player, uint8 attempt);
    event PlayerWon(uint256 indexed id, address player, uint8 attempts);

    modifier onlyWordmaster() {
        require(msg.sender == wordmaster || msg.sender == owner(), "Not wordmaster");
        _;
    }

    constructor(address wm) Ownable(msg.sender) {
        wordmaster = wm;
    }

    function createChallenge(externalEuint32 encWordHash, bytes calldata proof) external onlyWordmaster returns (uint256 id) {
        euint32 wordHash = FHE.fromExternal(encWordHash, proof);
        id = challengeCount++;
        challenges[id] = DailyChallenge({ secretWordHash: wordHash, date: block.timestamp,
            playersAttempted: 0, playersSolved: 0, prizePool: FHE.asEuint64(0) });
        FHE.allowThis(challenges[id].secretWordHash);
        FHE.allowThis(challenges[id].prizePool);
        emit ChallengeCreated(id, block.timestamp);
    }

    function addToPrizePool(uint256 challengeId, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        challenges[challengeId].prizePool = FHE.add(challenges[challengeId].prizePool, amount);
        FHE.allowThis(challenges[challengeId].prizePool);
    }

    function submitGuess(uint256 challengeId, externalEuint32 encGuessHash, bytes calldata proof) external {
        PlayerRound storage pr = rounds[challengeId][msg.sender];
        require(!pr.solved && pr.attemptsUsed < MAX_ATTEMPTS, "No attempts left");
        euint32 guessHash = FHE.fromExternal(encGuessHash, proof);
        pr.attemptsUsed++;
        if (pr.attemptsUsed == 1) {
            challenges[challengeId].playersAttempted++;
            pr.bestScore = FHE.asEuint8(0);
            FHE.allowThis(pr.bestScore);
        }
        // Check if guess matches secret
        ebool correct = FHE.eq(guessHash, challenges[challengeId].secretWordHash);
        if (FHE.isInitialized(correct)) {
            pr.solved = true;
            challenges[challengeId].playersSolved++;
            _playerWinnings[msg.sender] = FHE.add(_playerWinnings[msg.sender],
                FHE.div(challenges[challengeId].prizePool, 1));
            FHE.allowThis(_playerWinnings[msg.sender]);
            FHE.allow(_playerWinnings[msg.sender], msg.sender);
            emit PlayerWon(challengeId, msg.sender, pr.attemptsUsed);
        }
        FHE.allowThis(guessHash);
        emit GuessSubmitted(challengeId, msg.sender, pr.attemptsUsed);
    }

    function claimWinnings() external {
        euint64 win = _playerWinnings[msg.sender];
        _playerWinnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_playerWinnings[msg.sender]);
        FHE.allow(win, msg.sender);
    }

    function allowChallengeStats(uint256 challengeId, address viewer) external onlyWordmaster {
        FHE.allow(challenges[challengeId].secretWordHash, viewer);
        FHE.allow(challenges[challengeId].prizePool, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}