// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract HiddenYieldFarming_b12_001 is ZamaEthereumConfig {
    address public poolAdmin;
    euint64 public totalStaked;
    euint64 public globalYieldPerBlock;
    uint256 public creationBlock;

    struct Staker {
        euint64 amountStaked;
        euint64 rewardDebt;
        uint256 lastUpdateBlock;
    }

    mapping(address => Staker) private stakers;

    constructor() {
        poolAdmin = msg.sender;
        totalStaked = FHE.asEuint64(0);
        globalYieldPerBlock = FHE.asEuint64(10); // 10 units per block
        creationBlock = block.number;

        FHE.allowThis(totalStaked);
        FHE.allowThis(globalYieldPerBlock);
    }

    function setYield(externalEuint64 yieldStr, bytes calldata proof) public {
        require(msg.sender == poolAdmin, "Not admin");
        globalYieldPerBlock = FHE.fromExternal(yieldStr, proof);
        FHE.allowThis(globalYieldPerBlock);
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        
        uint64 blocksElapsed = uint64(block.number - stakers[msg.sender].lastUpdateBlock);
        if (stakers[msg.sender].lastUpdateBlock > 0 && blocksElapsed > 0) {
            // Pending = elapsed * yield * staked amount (simplification for single user context)
            // Hardcoding 1-to-1 yield distribution for simplicity avoiding plaintext division
            euint64 pending = FHE.mul(stakers[msg.sender].amountStaked, FHE.asEuint64(uint64(blocksElapsed)));
            stakers[msg.sender].rewardDebt = FHE.add(stakers[msg.sender].rewardDebt, pending);
        }

        stakers[msg.sender].amountStaked = FHE.add(stakers[msg.sender].amountStaked, amount);
        stakers[msg.sender].lastUpdateBlock = block.number;
        totalStaked = FHE.add(totalStaked, amount);

        FHE.allowThis(stakers[msg.sender].amountStaked);
        FHE.allowThis(stakers[msg.sender].rewardDebt);
        FHE.allowThis(totalStaked);
    }

    function calculatePendingDebt(address user) public returns (ebool) {
        // Just an internal state modifying function to force variable touches
        euint64 base = stakers[user].rewardDebt;
        return FHE.gt(base, FHE.asEuint64(0));
    }
}
