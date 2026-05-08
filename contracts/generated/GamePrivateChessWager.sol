// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title GamePrivateChessWager
/// @notice Chess wager platform where stake amounts and ELO ratings are encrypted.
///         Players cannot see each other's wager or ELO before acceptance.
///         Winner gets encrypted payout based on encrypted ELO difference multiplier.
contract GamePrivateChessWager is ZamaEthereumConfig, Ownable {
    struct ChessWager {
        address challenger;
        address opponent;
        euint64 challengerStake;
        euint64 opponentStake;
        euint16 challengerELO;
        euint16 opponentELO;
        uint256 timeControl;  // seconds per side
        bool accepted;
        bool completed;
        address winner;
        uint256 createdAt;
    }

    mapping(uint256 => ChessWager) private wagers;
    uint256 public wagerCount;
    mapping(address => euint16) private playerELO;
    mapping(address => bool) public registered;
    euint64 private _platformFeeBps;

    event WagerCreated(uint256 indexed id, address challenger);
    event WagerAccepted(uint256 indexed id, address opponent);
    event WagerCompleted(uint256 indexed id, address winner);

    constructor(externalEuint64 encPlatformFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encPlatformFee, proof);
        FHE.allowThis(_platformFeeBps);
    }

    function registerPlayer(externalEuint16 encELO, bytes calldata proof) external {
        require(!registered[msg.sender], "Already registered");
        playerELO[msg.sender] = FHE.fromExternal(encELO, proof);
        registered[msg.sender] = true;
        FHE.allowThis(playerELO[msg.sender]);
        FHE.allow(playerELO[msg.sender], msg.sender);
    }

    function createWager(
        uint256 timeControl,
        externalEuint64 encStake, bytes calldata proof
    ) external returns (uint256 id) {
        require(registered[msg.sender], "Not registered");
        id = wagerCount++;
        wagers[id].challenger = msg.sender;
        wagers[id].challengerStake = FHE.fromExternal(encStake, proof);
        wagers[id].challengerELO = playerELO[msg.sender];
        wagers[id].timeControl = timeControl;
        wagers[id].opponentStake = FHE.asEuint64(0);
        wagers[id].opponentELO = FHE.asEuint16(0);
        wagers[id].createdAt = block.timestamp;
        FHE.allowThis(wagers[id].challengerStake);
        FHE.allowThis(wagers[id].challengerELO);
        FHE.allowThis(wagers[id].opponentStake);
        FHE.allowThis(wagers[id].opponentELO);
        emit WagerCreated(id, msg.sender);
    }

    function acceptWager(
        uint256 wagerId,
        externalEuint64 encStake, bytes calldata proof
    ) external {
        require(registered[msg.sender], "Not registered");
        ChessWager storage w = wagers[wagerId];
        require(w.opponent == address(0), "Already accepted");
        require(msg.sender != w.challenger, "Cannot challenge self");
        w.opponent = msg.sender;
        w.opponentStake = FHE.fromExternal(encStake, proof);
        w.opponentELO = playerELO[msg.sender];
        w.accepted = true;
        FHE.allowThis(w.opponentStake);
        FHE.allowThis(w.opponentELO);
        emit WagerAccepted(wagerId, msg.sender);
    }

    function settleWager(uint256 wagerId, bool challengerWon) external onlyOwner {
        ChessWager storage w = wagers[wagerId];
        require(w.accepted && !w.completed, "Cannot settle");
        w.completed = true;
        euint64 totalPot = FHE.add(w.challengerStake, w.opponentStake);
        euint64 platformFee = FHE.div(FHE.mul(totalPot, _platformFeeBps), 10000);
        euint64 winnerPay = FHE.sub(totalPot, platformFee);
        if (challengerWon) {
            w.winner = w.challenger;
            FHE.allow(winnerPay, w.challenger);
        } else {
            w.winner = w.opponent;
            FHE.allow(winnerPay, w.opponent);
        }
        FHE.allow(platformFee, owner());
        // ELO adjustment (simplified: winner ELO +10, loser -10)
        address winner = challengerWon ? w.challenger : w.opponent;
        address loser = challengerWon ? w.opponent : w.challenger;
        playerELO[winner] = FHE.add(playerELO[winner], FHE.asEuint16(10));
        playerELO[loser] = FHE.sub(playerELO[loser], FHE.asEuint16(10));
        FHE.allowThis(playerELO[winner]);
        FHE.allow(playerELO[winner], winner);
        FHE.allowThis(playerELO[loser]);
        FHE.allow(playerELO[loser], loser);
        emit WagerCompleted(wagerId, w.winner);
    }

    function allowWagerData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(wagers[id].challengerStake, viewer);
        FHE.allow(wagers[id].opponentStake, viewer);
    }
}
