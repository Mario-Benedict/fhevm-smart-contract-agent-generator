// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title StakingLockedTerm_b4_007 - Fixed-term staking with encrypted reward tiers
contract StakingLockedTerm_b4_007 is ZamaEthereumConfig {
    address public owner;

    struct TermOption {
        uint256 lockDuration; // in seconds
        uint8 aprPercent;     // APR %
    }

    TermOption[] public termOptions;

    struct Position {
        euint64 amount;
        uint256 unlockTime;
        uint8 termIndex;
        bool claimed;
    }

    mapping(address => Position[]) private positions;
    euint64 private totalLocked;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalLocked = FHE.asEuint64(0);
        FHE.allowThis(totalLocked);
        // 30 day = 5%, 90 day = 10%, 365 day = 20%
        termOptions.push(TermOption(30 days, 5));
        termOptions.push(TermOption(90 days, 10));
        termOptions.push(TermOption(365 days, 20));
    }

    function stake(externalEuint64 amountStr, bytes calldata proof, uint8 termIndex) public {
        require(termIndex < termOptions.length, "Invalid term");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        TermOption memory term = termOptions[termIndex];

        Position memory pos;
        pos.amount = amount;
        pos.unlockTime = block.timestamp + term.lockDuration;
        pos.termIndex = termIndex;
        pos.claimed = false;
        FHE.allowThis(pos.amount);
        positions[msg.sender].push(pos);

        totalLocked = FHE.add(totalLocked, amount);
        FHE.allowThis(totalLocked);
    }

    function unstake(uint256 posIndex) public {
        Position storage pos = positions[msg.sender][posIndex];
        require(!pos.claimed, "Already claimed");
        require(block.timestamp >= pos.unlockTime, "Still locked");
        pos.claimed = true;

        uint256 elapsed = pos.unlockTime - (pos.unlockTime - termOptions[pos.termIndex].lockDuration);
        uint64 rewardPct = uint64(termOptions[pos.termIndex].aprPercent) * uint64(elapsed) / uint64(365 days);
        euint64 reward = FHE.mul(pos.amount, FHE.asEuint64(uint64(rewardPct)));
        euint64 total = FHE.add(pos.amount, reward);

        totalLocked = FHE.sub(totalLocked, pos.amount);
        FHE.allowThis(totalLocked);
        FHE.allow(total, msg.sender);
    }

    function getPositionCount(address user) public view returns (uint256) {
        return positions[user].length;
    }
}
