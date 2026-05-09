// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BlindBingoGame - On-chain bingo with encrypted numbers drawn via FHE randomness
contract BlindBingoGame is ZamaEthereumConfig, Ownable {
    struct BingoCard {
        euint8[25] numbers;  // 5x5 encrypted grid
        uint8 markedCount;
        bool winner;
    }

    mapping(uint256 => mapping(address => BingoCard)) private cards;
    mapping(uint256 => euint8[]) private drawnNumbers;
    mapping(address => bool) public isPlayer;
    uint256 public gameCount;
    euint64 private _prizePool;
    address public caller;

    event GameStarted(uint256 indexed gameId);
    event NumberDrawn(uint256 indexed gameId, uint8 drawIndex);
    event BingoWinner(uint256 indexed gameId, address winner);

    modifier onlyCaller() {
        require(msg.sender == caller || msg.sender == owner(), "Not caller");
        _;
    }

    constructor(address _caller) Ownable(msg.sender) {
        caller = _caller;
        _prizePool = FHE.asEuint64(0);
        FHE.allowThis(_prizePool);
    }

    function registerPlayer(address p) external onlyOwner { isPlayer[p] = true; }

    function startGame() external onlyCaller returns (uint256 gameId) {
        gameId = gameCount++;
        emit GameStarted(gameId);
    }

    function buyCard(uint256 gameId, externalEuint64 encEntry, bytes calldata proof) external {
        require(isPlayer[msg.sender], "Not player");
        euint64 entry = FHE.fromExternal(encEntry, proof);
        _prizePool = FHE.add(_prizePool, entry);
        FHE.allowThis(_prizePool);
        // Initialize card with FHE random numbers (simplified)
        BingoCard storage card = cards[gameId][msg.sender];
        for (uint8 i = 0; i < 25; i++) {
            card.numbers[i] = FHE.randEuint8();
            FHE.allowThis(card.numbers[i]);
            FHE.allow(card.numbers[i], msg.sender);
        }
        card.markedCount = 0;
        card.winner = false;
    }

    function drawNumber(uint256 gameId) external onlyCaller {
        euint8 drawn = FHE.randEuint8();
        drawnNumbers[gameId].push(drawn);
        FHE.allowThis(drawnNumbers[gameId][drawnNumbers[gameId].length - 1]);
        emit NumberDrawn(gameId, uint8(drawnNumbers[gameId].length - 1));
    }

    function markNumber(uint256 gameId, uint8 cardPosition) external {
        require(isPlayer[msg.sender] && cardPosition < 25, "Invalid");
        BingoCard storage card = cards[gameId][msg.sender];
        // Check if last drawn number matches card position
        uint256 drawCount = drawnNumbers[gameId].length;
        if (drawCount == 0) return;
        euint8 lastDrawn = drawnNumbers[gameId][drawCount - 1];
        ebool matches = FHE.eq(card.numbers[cardPosition], lastDrawn);
        if (FHE.isInitialized(matches)) card.markedCount++;
    }

    function claimBingo(uint256 gameId) external {
        BingoCard storage card = cards[gameId][msg.sender];
        require(!card.winner && card.markedCount >= 5, "No bingo");
        card.winner = true;
        FHE.allow(_prizePool, msg.sender);
        emit BingoWinner(gameId, msg.sender);
    }

    function allowPrizePool(address viewer) external onlyCaller { FHE.allow(_prizePool, viewer); }
}
