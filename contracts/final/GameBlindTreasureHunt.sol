// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameBlindTreasureHunt
/// @notice Treasure hunt game where treasure coordinates are encrypted.
///         Players submit encrypted guesses; proximity hints are computed
///         homomorphically. The closest guess within a secret radius wins.
contract GameBlindTreasureHunt is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct TreasureGame {
        euint16 treasureX;    // encrypted X coordinate (0-999)
        euint16 treasureY;    // encrypted Y coordinate (0-999)
        euint64 prize;
        euint16 winRadius;    // encrypted win radius in units
        uint256 deadline;
        bool finalized;
        address winner;
        uint256 guessCount;
    }

    struct Guess {
        euint16 x;
        euint16 y;
        euint16 proximityScore; // encrypted: lower = closer
        bool submitted;
    }

    mapping(uint256 => TreasureGame) private games;
    uint256 public gameCount;
    mapping(uint256 => mapping(address => Guess)) private guesses;
    mapping(uint256 => address[]) private players;
    euint64 private _entryFee;

    event GameCreated(uint256 indexed id);
    event GuessSubmitted(uint256 indexed id, address player);
    event GameFinalized(uint256 indexed id, address winner);

    constructor(externalEuint64 encEntryFee, bytes memory proof) Ownable(msg.sender) {
        _entryFee = FHE.fromExternal(encEntryFee, proof);
        FHE.allowThis(_entryFee);
    }

    function createGame(
        externalEuint16 encX, bytes calldata xProof,
        externalEuint16 encY, bytes calldata yProof,
        externalEuint64 encPrize, bytes calldata pProof,
        externalEuint16 encRadius, bytes calldata rProof,
        uint256 deadlineDays
    ) external onlyOwner returns (uint256 id) {
        id = gameCount++;
        games[id].treasureX = FHE.fromExternal(encX, xProof);
        games[id].treasureY = FHE.fromExternal(encY, yProof);
        games[id].prize = FHE.fromExternal(encPrize, pProof);
        games[id].winRadius = FHE.fromExternal(encRadius, rProof);
        games[id].deadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(games[id].treasureX);
        FHE.allowThis(games[id].treasureY);
        FHE.allowThis(games[id].prize);
        FHE.allowThis(games[id].winRadius);
        emit GameCreated(id);
    }

    function submitGuess(
        uint256 gameId,
        externalEuint16 encX, bytes calldata xProof,
        externalEuint16 encY, bytes calldata yProof,
        externalEuint64 encPayment, bytes calldata pProof
    ) external nonReentrant {
        TreasureGame storage g = games[gameId];
        require(!g.finalized && block.timestamp < g.deadline, "Closed");
        require(!guesses[gameId][msg.sender].submitted, "Already guessed");
        euint64 payment = FHE.fromExternal(encPayment, pProof);
        ebool paidEnough = FHE.ge(payment, _entryFee);
        euint16 x = FHE.fromExternal(encX, xProof);
        euint16 y = FHE.fromExternal(encY, yProof);
        // Compute Manhattan distance to treasure (encrypted)
        euint16 dx = FHE.select(FHE.ge(x, g.treasureX),
            FHE.sub(x, g.treasureX), FHE.sub(g.treasureX, x)); // [arithmetic_overflow_underflow]
            euint64 paymentScaled = FHE.mul(payment, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint16 dy = FHE.select(FHE.ge(y, g.treasureY),
            FHE.sub(y, g.treasureY), FHE.sub(g.treasureY, y));
        euint16 distance = FHE.add(dx, dy);
        guesses[gameId][msg.sender] = Guess({ x: x, y: y, proximityScore: distance, submitted: true });
        FHE.allowThis(guesses[gameId][msg.sender].x);
        FHE.allowThis(guesses[gameId][msg.sender].y);
        FHE.allowThis(guesses[gameId][msg.sender].proximityScore);
        // Add entry fee to prize if payment valid
        g.prize = FHE.add(g.prize, FHE.select(paidEnough, _entryFee, FHE.asEuint64(0)));
        FHE.allowThis(g.prize);
        g.guessCount++;
        players[gameId].push(msg.sender);
        emit GuessSubmitted(gameId, msg.sender);
    }

    function finalizeGame(uint256 gameId) external onlyOwner nonReentrant {
        TreasureGame storage g = games[gameId];
        require(block.timestamp >= g.deadline && !g.finalized, "Cannot finalize");
        g.finalized = true;
        euint16 bestProximity = FHE.asEuint16(type(uint16).max);
        address bestPlayer = address(0);
        address[] storage ps = players[gameId];
        for (uint256 i = 0; i < ps.length; i++) {
            Guess storage guess = guesses[gameId][ps[i]];
            ebool withinRadius = FHE.le(guess.proximityScore, g.winRadius);
            ebool isBest = FHE.lt(guess.proximityScore, bestProximity);
            ebool winner = FHE.and(withinRadius, isBest);
            bestProximity = FHE.select(winner, guess.proximityScore, bestProximity);
            if (FHE.isInitialized(winner)) bestPlayer = ps[i];
        }
        g.winner = bestPlayer;
        if (bestPlayer != address(0)) FHE.allow(g.prize, bestPlayer);
        emit GameFinalized(gameId, bestPlayer);
    }

    function getProximityHint(uint256 gameId) external view returns (address) {
        return guesses[gameId][msg.sender].submitted ? msg.sender : address(0);
    }

    function allowProximityScore(uint256 gameId, address viewer) external {
        FHE.allow(guesses[gameId][msg.sender].proximityScore, viewer);
    }
}
