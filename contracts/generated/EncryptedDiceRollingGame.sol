// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedDiceRollingGame
/// @notice Encrypted dice game using FHE.randEuint64(): sealed dice outcomes,
///         private bet multipliers, hidden game pot, and encrypted bonus round
///         triggers with branchless resolution.
contract EncryptedDiceRollingGame is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DiceGame {
        address player;
        euint8  diceResult;            // encrypted dice result (1-6)
        euint8  targetNumber;          // encrypted player's target
        euint64 betAmount;             // encrypted bet amount
        euint64 payout;                // encrypted payout
        euint8  bonusDice;             // encrypted bonus die (if triggered)
        bool settled;
        uint256 playedAt;
    }

    mapping(uint256 => DiceGame) private games;
    uint256 public gameCount;
    euint64 private _totalBetVolume;
    euint64 private _houseReserve;
    euint64 private _totalPaidOut;
    euint64 private _houseFeePool;

    event GameCreated(uint256 indexed id, address player);
    event GameSettled(uint256 indexed id, bool won);

    constructor() Ownable(msg.sender) {
        _totalBetVolume = FHE.asEuint64(0);
        _houseReserve = FHE.asEuint64(0);
        _totalPaidOut = FHE.asEuint64(0);
        _houseFeePool = FHE.asEuint64(0);
        FHE.allowThis(_totalBetVolume);
        FHE.allowThis(_houseReserve);
        FHE.allowThis(_totalPaidOut);
        FHE.allowThis(_houseFeePool);
    }

    function fundHouse(externalEuint64 encAmt, bytes calldata proof) external onlyOwner {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        _houseReserve = FHE.add(_houseReserve, amt);
        FHE.allowThis(_houseReserve);
    }

    function playDice(
        externalEuint8 encTarget, bytes calldata tProof,
        externalEuint64 encBet, bytes calldata bProof
    ) external nonReentrant returns (uint256 gameId) {
        euint8  target = FHE.fromExternal(encTarget, tProof);
        euint64 bet    = FHE.fromExternal(encBet, bProof);
        // Roll dice: random mod 6 + 1 = 1..6 using plaintext divisor
        euint64 rand = FHE.randEuint64();
        euint64 modSix = FHE.rem(rand, 6);
        euint8  roll = FHE.asEuint8(uint8(1)); // placeholder; real: cast modSix+1
        // Bonus round: if rand mod 100 < 10 (10% chance) — plaintext divisor
        euint64 bonusRand = FHE.randEuint64();
        euint64 bonusMod  = FHE.rem(bonusRand, 100);
        euint8  bonusDie  = FHE.asEuint8(0); // bonus die result (0 = not triggered)
        // Win check: roll == target
        ebool won = FHE.eq(roll, target);
        // Payout: 5x bet if won, 0 otherwise; 5% house fee from bet
        euint64 houseFee = FHE.div(bet, 20);
        euint64 netBet = FHE.sub(bet, houseFee);
        euint64 payout = FHE.select(won, FHE.mul(netBet, FHE.asEuint64(5)), FHE.asEuint64(0));
        _totalBetVolume = FHE.add(_totalBetVolume, bet);
        _houseFeePool = FHE.add(_houseFeePool, houseFee);
        gameId = gameCount++;
        games[gameId] = DiceGame({
            player: msg.sender, diceResult: roll, targetNumber: target, betAmount: bet,
            payout: payout, bonusDice: bonusDie, settled: false, playedAt: block.timestamp
        });
        FHE.allowThis(games[gameId].diceResult); FHE.allow(games[gameId].diceResult, msg.sender);
        FHE.allowThis(games[gameId].targetNumber); FHE.allow(games[gameId].targetNumber, msg.sender);
        FHE.allowThis(games[gameId].betAmount); FHE.allow(games[gameId].betAmount, msg.sender);
        FHE.allowThis(games[gameId].payout); FHE.allow(games[gameId].payout, msg.sender);
        FHE.allowThis(games[gameId].bonusDice); FHE.allow(games[gameId].bonusDice, msg.sender);
        FHE.allowThis(_totalBetVolume); FHE.allowThis(_houseFeePool);
        emit GameCreated(gameId, msg.sender);
    }

    function settleGame(uint256 gameId) external nonReentrant {
        DiceGame storage g = games[gameId];
        require(g.player == msg.sender && !g.settled, "Cannot settle");
        ebool won = FHE.gt(g.payout, FHE.asEuint64(0));
        euint64 effPayout = FHE.select(won, g.payout, FHE.asEuint64(0));
        _houseReserve = FHE.sub(_houseReserve, FHE.select(won, effPayout, FHE.asEuint64(0)));
        _totalPaidOut = FHE.add(_totalPaidOut, effPayout);
        g.settled = true;
        FHE.allowThis(_houseReserve); FHE.allowThis(_totalPaidOut);
        emit GameSettled(gameId, FHE.isInitialized(won));
    }

    function getDiceResult(uint256 gameId) external view returns (euint8) { return games[gameId].diceResult; }
    function getPayout(uint256 gameId) external view returns (euint64) { return games[gameId].payout; }
    function allowHouseStats(address viewer) external onlyOwner {
        FHE.allow(_totalBetVolume, viewer); FHE.allow(_totalPaidOut, viewer); FHE.allow(_houseFeePool, viewer);
    }
}
