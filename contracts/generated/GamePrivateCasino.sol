// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GamePrivateCasino
/// @notice Multi-game casino with encrypted house edge per game type.
///         Players cannot see the exact house edge; outcomes are FHE-random.
contract GamePrivateCasino is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum GameType { Slots, Roulette, Blackjack, Dice }

    struct GameConfig {
        euint16 houseEdgeBps;  // encrypted house edge
        euint64 maxBet;        // encrypted max bet per game
        euint64 minBet;        // encrypted min bet
        bool active;
    }

    struct GameSession {
        address player;
        GameType gameType;
        euint64 betAmount;
        euint64 payout;
        bool completed;
        bool won;
    }

    mapping(GameType => GameConfig) private configs;
    mapping(uint256 => GameSession) private sessions;
    uint256 public sessionCount;
    euint64 private _casinoReserve;
    euint64 private _totalWagered;

    event ConfigSet(GameType gameType);
    event GamePlayed(uint256 indexed sessionId, address player, GameType gameType);

    constructor(
        externalEuint64 encSlotsEdge, bytes memory sProof,
        externalEuint64 encRouletteEdge, bytes memory rProof
    ) Ownable(msg.sender) {
        _casinoReserve = FHE.asEuint64(0);
        _totalWagered = FHE.asEuint64(0);
        // Initialize slot config
        configs[GameType.Slots].houseEdgeBps = FHE.fromExternal(encSlotsEdge, sProof);
        configs[GameType.Slots].maxBet = FHE.asEuint64(0);
        configs[GameType.Slots].minBet = FHE.asEuint64(0);
        configs[GameType.Slots].active = true;
        configs[GameType.Roulette].houseEdgeBps = FHE.fromExternal(encRouletteEdge, rProof);
        configs[GameType.Roulette].maxBet = FHE.asEuint64(0);
        configs[GameType.Roulette].minBet = FHE.asEuint64(0);
        configs[GameType.Roulette].active = true;
        FHE.allowThis(configs[GameType.Slots].houseEdgeBps);
        FHE.allowThis(configs[GameType.Roulette].houseEdgeBps);
        FHE.allowThis(_casinoReserve);
        FHE.allowThis(_totalWagered);
    }

    function setGameConfig(
        GameType gType,
        externalEuint16 encEdge, bytes calldata eProof,
        externalEuint64 encMax, bytes calldata maxProof,
        externalEuint64 encMin, bytes calldata minProof
    ) external onlyOwner {
        configs[gType].houseEdgeBps = FHE.fromExternal(encEdge, eProof);
        configs[gType].maxBet = FHE.fromExternal(encMax, maxProof);
        configs[gType].minBet = FHE.fromExternal(encMin, minProof);
        configs[gType].active = true;
        FHE.allowThis(configs[gType].houseEdgeBps);
        FHE.allowThis(configs[gType].maxBet);
        FHE.allowThis(configs[gType].minBet);
        emit ConfigSet(gType);
    }

    function fundCasino(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _casinoReserve = FHE.add(_casinoReserve, amount);
        FHE.allowThis(_casinoReserve);
    }

    function play(
        GameType gType,
        externalEuint64 encBet, bytes calldata proof
    ) external nonReentrant returns (uint256 sessionId) {
        require(configs[gType].active, "Game not active");
        euint64 bet = FHE.fromExternal(encBet, proof);
        ebool betInRange = FHE.and(
            FHE.ge(bet, configs[gType].minBet),
            FHE.le(bet, configs[gType].maxBet)
        );
        euint64 validBet = FHE.select(betInRange, bet, FHE.asEuint64(0));
        // Generate random outcome
        euint64 rand = FHE.randEuint64();
        euint64 threshold = FHE.sub(FHE.asEuint64(10000), configs[gType].houseEdgeBps);
        euint64 randMod = FHE.rem(rand, 10000);
        ebool playerWins = FHE.lt(randMod, threshold);
        // Payout: 2x on win (simplified)
        euint64 payout = FHE.select(playerWins, FHE.mul(validBet, 2), FHE.asEuint64(0));
        ebool casinoCanPay = FHE.ge(_casinoReserve, payout);
        euint64 actualPayout = FHE.select(casinoCanPay, payout, FHE.asEuint64(0));
        _casinoReserve = FHE.sub(
            FHE.add(_casinoReserve, validBet),
            actualPayout
        );
        _totalWagered = FHE.add(_totalWagered, validBet);
        sessionId = sessionCount++;
        sessions[sessionId] = GameSession({
            player: msg.sender, gameType: gType,
            betAmount: validBet, payout: actualPayout,
            completed: true, won: FHE.isInitialized(playerWins)
        });
        FHE.allowThis(sessions[sessionId].betAmount);
        FHE.allowThis(sessions[sessionId].payout);
        FHE.allow(sessions[sessionId].payout, msg.sender);
        FHE.allowThis(_casinoReserve);
        FHE.allowThis(_totalWagered);
        emit GamePlayed(sessionId, msg.sender, gType);
    }

    function allowCasinoStats(address viewer) external onlyOwner {
        FHE.allow(_casinoReserve, viewer);
        FHE.allow(_totalWagered, viewer);
    }
}
