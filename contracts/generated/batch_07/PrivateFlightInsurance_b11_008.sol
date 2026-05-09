// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateFlightInsurance_b11_008 is ZamaEthereumConfig {
    address public oracle;
    euint64 public delayThreshold; // e.g., minutes
    euint64 public payoutAmount;
    mapping(address => euint64) private pendingPayouts;

    constructor() {
        oracle = msg.sender;
        delayThreshold = FHE.asEuint64(120); 
        payoutAmount = FHE.asEuint64(5000);
        FHE.allowThis(delayThreshold);
        FHE.allowThis(payoutAmount);
    }

    function reportDelay(address user, externalEuint64 delayStr, bytes calldata proof) public {
        require(msg.sender == oracle, "Not oracle");
        euint64 delay = FHE.fromExternal(delayStr, proof);
        ebool isDelayed = FHE.ge(delay, delayThreshold);
        
        euint64 payout = FHE.select(isDelayed, payoutAmount, FHE.asEuint64(0));
        pendingPayouts[user] = FHE.add(pendingPayouts[user], payout);
        FHE.allowThis(pendingPayouts[user]);
    }
}
