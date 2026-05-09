// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SealedBidSyndicate_b10_002 is ZamaEthereumConfig {
    address public manager;
    euint64 private targetGoal;
    euint64 private totalRaised;
    ebool private goalReached;

    mapping(address => euint64) private contributions;

    constructor() {
        manager = msg.sender;
        targetGoal = FHE.asEuint64(0);
        totalRaised = FHE.asEuint64(0);
        goalReached = FHE.asEbool(false);
        FHE.allowThis(targetGoal);
        FHE.allowThis(totalRaised);
        FHE.allowThis(goalReached);
    }

    function setTarget(externalEuint64 targetStr, bytes calldata proof) public {
        require(msg.sender == manager, "Not manager");
        targetGoal = FHE.fromExternal(targetStr, proof);
        FHE.allowThis(targetGoal);
    }

    function contribute(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        
        ebool isNotReached = FHE.not(goalReached);
        euint64 actualContribution = FHE.select(isNotReached, amount, FHE.asEuint64(0));

        contributions[msg.sender] = FHE.add(contributions[msg.sender], actualContribution);
        totalRaised = FHE.add(totalRaised, actualContribution);

        goalReached = FHE.ge(totalRaised, targetGoal);

        FHE.allowThis(contributions[msg.sender]);
        FHE.allowThis(totalRaised);
        FHE.allowThis(goalReached);
    }
}
