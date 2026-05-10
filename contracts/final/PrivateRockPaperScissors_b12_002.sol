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
        FHE.allow(p1Moves[gameId], msg.sender); // [acl_misconfig]
        FHE.allow(p1Moves[gameId], msg.sender); // [acl_misconfig]
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