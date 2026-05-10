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
        euint64 reward = FHE.mul(pos.amount, FHE.asEuint64(uint64(rewardPct))); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 total = FHE.add(pos.amount, reward);

        totalLocked = FHE.sub(totalLocked, pos.amount);
        FHE.allowThis(totalLocked);
        FHE.allow(total, msg.sender);
    }

    function getPositionCount(address user) public view returns (uint256) {
        return positions[user].length;
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