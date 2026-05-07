// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateRockPaperScissors_b12_002 is ZamaEthereumConfig {
    // 1: Rock, 2: Paper, 3: Scissors
    mapping(address => euint8) private p1Moves;
    mapping(address => euint8) private p2Moves;

    mapping(address => ebool) private p1Wins;
    mapping(address => ebool) private isDraw;

    constructor() {}

    function commitP1Move(address gameId, externalEuint8 moveStr, bytes calldata proof) public {
        p1Moves[gameId] = FHE.fromExternal(moveStr, proof);
        FHE.allowThis(p1Moves[gameId]);
    }

    function commitP2Move(address gameId, externalEuint8 moveStr, bytes calldata proof) public {
        p2Moves[gameId] = FHE.fromExternal(moveStr, proof);
        FHE.allowThis(p2Moves[gameId]);
    }

    function resolveGame(address gameId) public {
        euint8 m1 = p1Moves[gameId];
        euint8 m2 = p2Moves[gameId];

        // Draw
        ebool draw = FHE.eq(m1, m2);

        // P1 Wins logic: 
        // (1 beats 3), (2 beats 1), (3 beats 2)
        ebool r1 = FHE.and(FHE.eq(m1, FHE.asEuint8(1)), FHE.eq(m2, FHE.asEuint8(3)));
        ebool r2 = FHE.and(FHE.eq(m1, FHE.asEuint8(2)), FHE.eq(m2, FHE.asEuint8(1)));
        ebool r3 = FHE.and(FHE.eq(m1, FHE.asEuint8(3)), FHE.eq(m2, FHE.asEuint8(2)));

        ebool win = FHE.or(r1, FHE.or(r2, r3));

        isDraw[gameId] = draw;
        p1Wins[gameId] = win;

        FHE.allowThis(isDraw[gameId]);
        FHE.allowThis(p1Wins[gameId]);
    }
}
