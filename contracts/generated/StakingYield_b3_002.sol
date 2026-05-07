// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract StakingYield_b3_002 is ZamaEthereumConfig {
    mapping(address => euint64) private stakes;
    mapping(address => uint256) public lastStakeTime;
    
    euint64 private rewardPool;

    constructor() {
        rewardPool = FHE.asEuint64(1000000);
        FHE.allowThis(rewardPool);
    }

    function stake(externalEuint64 amountStr, bytes calldata inputProof) public {
        euint64 amount = FHE.fromExternal(amountStr, inputProof);
        stakes[msg.sender] = FHE.add(stakes[msg.sender], amount);
        FHE.allowThis(stakes[msg.sender]);
        lastStakeTime[msg.sender] = block.timestamp;
    }
}
