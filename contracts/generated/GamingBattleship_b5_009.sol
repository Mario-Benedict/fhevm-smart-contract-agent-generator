// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingBattleship_b5_009 - Encrypted battleship game
contract GamingBattleship_b5_009 is ZamaEthereumConfig {
    address public player1;
    address public player2;
    bool public gameStarted;

    // Each player has a 5x5 grid encoded as 25 ebool slots
    // For simplicity we use 5 euint8 rows, each bit = ship presence
    mapping(address => euint8[5]) private grids;
    mapping(address => bool) private gridSubmitted;

    mapping(address => uint8) public hits;
    mapping(address => uint8) public misses;
    uint8 public constant TOTAL_SHIPS = 5;

    constructor(address _player2) {
        player1 = msg.sender;
        player2 = _player2;
    }

    function submitGrid(
        externalEuint8 r0, externalEuint8 r1, externalEuint8 r2, externalEuint8 r3, externalEuint8 r4,
        bytes calldata p0, bytes calldata p1, bytes calldata p2, bytes calldata p3, bytes calldata p4
    ) public {
        require(msg.sender == player1 || msg.sender == player2, "Not a player");
        require(!gridSubmitted[msg.sender], "Already submitted");
        grids[msg.sender][0] = FHE.fromExternal(r0, p0);
        grids[msg.sender][1] = FHE.fromExternal(r1, p1);
        grids[msg.sender][2] = FHE.fromExternal(r2, p2);
        grids[msg.sender][3] = FHE.fromExternal(r3, p3);
        grids[msg.sender][4] = FHE.fromExternal(r4, p4);
        for (uint8 i = 0; i < 5; i++) {
            FHE.allowThis(grids[msg.sender][i]);
        }
        gridSubmitted[msg.sender] = true;
        if (gridSubmitted[player1] && gridSubmitted[player2]) {
            gameStarted = true;
        }
    }

    function fire(address target, uint8 row) public returns (ebool hit) {
        require(gameStarted, "Game not started");
        require(msg.sender == player1 || msg.sender == player2, "Not a player");
        require(target != msg.sender, "Cannot fire at self");
        require(row < 5, "Invalid row");

        // Check if row has any ship bit set (simplified: row != 0 means hit)
        hit = FHE.ne(grids[target][row], FHE.asEuint8(0));
        FHE.allow(hit, msg.sender);
        FHE.allowThis(hit);
    }
}
