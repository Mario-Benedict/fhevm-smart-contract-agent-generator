// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SecretDiceLeague - On-chain dice tournament with encrypted rolls and leaderboard
contract SecretDiceLeague is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Player {
        euint64 totalScore;
        uint32 roundsPlayed;
        bool registered;
    }

    struct Round {
        uint256 startTime;
        uint256 endTime;
        euint64 prizePool;
        address winner;
        bool finalized;
    }

    mapping(address => Player) public players;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => euint8)) private roundRolls;
    mapping(uint256 => mapping(address => bool)) public hasRolled;
    uint256 public currentRound;
    uint16 public entryFeeUSD;

    event PlayerRegistered(address indexed player);
    event DiceRolled(uint256 indexed round, address indexed player);
    event RoundFinalized(uint256 indexed round, address indexed winner);

    constructor(uint16 _entryFeeUSD) Ownable(msg.sender) {
        entryFeeUSD = _entryFeeUSD;
    }

    function register() external {
        require(!players[msg.sender].registered, "Already registered");
        players[msg.sender].totalScore = FHE.asEuint64(0);
        players[msg.sender].registered = true;
        FHE.allowThis(players[msg.sender].totalScore);
        FHE.allow(players[msg.sender].totalScore, msg.sender);
        emit PlayerRegistered(msg.sender);
    }

    function startRound(uint256 duration) external onlyOwner {
        uint256 roundId = currentRound++;
        Round storage r = rounds[roundId];
        r.startTime = block.timestamp;
        r.endTime = block.timestamp + duration;
        r.prizePool = FHE.asEuint64(0);
        FHE.allowThis(r.prizePool);
    }

    function rollDice(uint256 roundId) external nonReentrant {
        require(players[msg.sender].registered, "Not registered");
        require(!hasRolled[roundId][msg.sender], "Already rolled");
        Round storage r = rounds[roundId];
        require(block.timestamp >= r.startTime && block.timestamp <= r.endTime, "Round not active");

        euint8 roll = FHE.randEuint8();
        euint8 capped = FHE.rem(roll, 6);
        euint8 result = FHE.add(capped, FHE.asEuint8(1)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        roundRolls[roundId][msg.sender] = result;
        FHE.allowThis(roundRolls[roundId][msg.sender]);
        FHE.allow(roundRolls[roundId][msg.sender], msg.sender);

        players[msg.sender].totalScore = FHE.add(players[msg.sender].totalScore, FHE.asEuint64(0));
        players[msg.sender].roundsPlayed++;
        hasRolled[roundId][msg.sender] = true;
        emit DiceRolled(roundId, msg.sender);
    }

    function addPrize(uint256 roundId, externalEuint64 encPrize, bytes calldata inputProof)
        external
        onlyOwner
    {
        euint64 prize = FHE.fromExternal(encPrize, inputProof);
        rounds[roundId].prizePool = FHE.add(rounds[roundId].prizePool, prize);
        FHE.allowThis(rounds[roundId].prizePool);
    }

    function finalizeRound(uint256 roundId, address winner) external onlyOwner {
        Round storage r = rounds[roundId];
        require(block.timestamp > r.endTime, "Not ended");
        require(!r.finalized, "Done");
        r.winner = winner;
        r.finalized = true;
        FHE.allow(r.prizePool, winner);
        emit RoundFinalized(roundId, winner);
    }

    function getMyRoll(uint256 roundId) external view returns (euint8) {
        return roundRolls[roundId][msg.sender];
    }

    function getMyScore() external view returns (euint64) {
        return players[msg.sender].totalScore;
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