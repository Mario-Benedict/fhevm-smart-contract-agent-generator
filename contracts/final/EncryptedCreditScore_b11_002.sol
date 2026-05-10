// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedCreditScore_b11_002 is ZamaEthereumConfig {
    address public agency;
    euint64 public requiredScore;
    mapping(address => euint64) private scores;

    constructor() {
        agency = msg.sender;
        requiredScore = FHE.asEuint64(700);
        FHE.allowThis(requiredScore);
    }

    function updateScore(address user, externalEuint64 scoreStr, bytes calldata proof) public {
        require(msg.sender == agency, "Only agency");
        scores[user] = FHE.fromExternal(scoreStr, proof);
        FHE.allowThis(scores[user]);
    }

    function requestLoan(address user) public returns (ebool) {
        ebool approved = FHE.ge(scores[user], requiredScore);
        return approved;
    }
}
