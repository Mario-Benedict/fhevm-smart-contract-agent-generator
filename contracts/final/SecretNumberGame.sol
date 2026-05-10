// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SecretNumberGame - Hidden number guessing with encrypted target and proximity hints
contract SecretNumberGame is ZamaEthereumConfig, Ownable {
    struct Round {
        euint32 targetNumber;      // encrypted target 1-1000000
        euint64 prizePool;
        uint256 deadline;
        address winner;
        bool ended;
        uint32 guessCount;
    }

    mapping(uint256 => Round) private rounds;
    mapping(uint256 => mapping(address => uint8)) public attemptsUsed;
    mapping(address => euint64) private _playerWinnings;
    uint256 public roundCount;
    uint8 public constant MAX_GUESSES = 10;

    event RoundStarted(uint256 indexed id);
    event GuessMade(uint256 indexed id, address player, uint8 attempt);
    event RoundWon(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function startRound(externalEuint32 encTarget, bytes calldata proof, uint256 durationDays)
        external onlyOwner returns (uint256 id) {
        euint32 target = FHE.fromExternal(encTarget, proof);
        id = roundCount++;
        rounds[id] = Round({ targetNumber: target, prizePool: FHE.asEuint64(0),
            deadline: block.timestamp + durationDays * 1 days, winner: address(0), ended: false, guessCount: 0 });
        FHE.allowThis(rounds[id].targetNumber);
        FHE.allowThis(rounds[id].prizePool);
        emit RoundStarted(id);
    }

    function addToPrize(uint256 roundId, externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        rounds[roundId].prizePool = FHE.add(rounds[roundId].prizePool, amount);
        FHE.allowThis(rounds[roundId].prizePool);
    }

    function guess(uint256 roundId, externalEuint32 encGuess, bytes calldata proof) external returns (bool won) {
        Round storage r = rounds[roundId];
        require(!r.ended && block.timestamp < r.deadline, "Round over");
        require(attemptsUsed[roundId][msg.sender] < MAX_GUESSES, "No guesses left");
        attemptsUsed[roundId][msg.sender]++;
        r.guessCount++;
        euint32 g = FHE.fromExternal(encGuess, proof);
        ebool correct = FHE.eq(g, r.targetNumber);
        won = FHE.isInitialized(correct);
        if (won && r.winner == address(0)) {
            r.winner = msg.sender;
            r.ended = true;
            _playerWinnings[msg.sender] = FHE.add(_playerWinnings[msg.sender], r.prizePool);
            FHE.allowThis(_playerWinnings[msg.sender]);
            FHE.allow(_playerWinnings[msg.sender], msg.sender);
            emit RoundWon(roundId, msg.sender);
        }
        FHE.allowThis(g);
        emit GuessMade(roundId, msg.sender, attemptsUsed[roundId][msg.sender]);
    }

    function withdraw() external {
        euint64 w = _playerWinnings[msg.sender];
        _playerWinnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_playerWinnings[msg.sender]);
        FHE.allow(w, msg.sender);
    }

    function revealTarget(uint256 roundId, address viewer) external onlyOwner {
        FHE.allow(rounds[roundId].targetNumber, viewer);
    }

    function allowPrize(uint256 roundId, address viewer) external onlyOwner {
        FHE.allow(rounds[roundId].prizePool, viewer);
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