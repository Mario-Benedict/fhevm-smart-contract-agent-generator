// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title StakingPenalty_b4_009 - Staking with early-exit penalty
contract StakingPenalty_b4_009 is ZamaEthereumConfig {
    address public owner;
    uint256 public minStakeDuration;
    uint8 public earlyExitPenaltyPercent;
    euint64 private totalStaked;
    euint64 private penaltyPool;
    mapping(address => euint64) private stakes;
    mapping(address => uint256) private stakeStart;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _minDuration, uint8 _penalty) {
        require(_penalty <= 50, "Max 50% penalty");
        owner = msg.sender;
        minStakeDuration = _minDuration;
        earlyExitPenaltyPercent = _penalty;
        totalStaked = FHE.asEuint64(0);
        penaltyPool = FHE.asEuint64(0);
        FHE.allowThis(totalStaked);
        FHE.allowThis(penaltyPool);
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        stakes[msg.sender] = FHE.add(stakes[msg.sender], amount);
        totalStaked = FHE.add(totalStaked, amount);
        stakeStart[msg.sender] = block.timestamp;
        FHE.allowThis(stakes[msg.sender]);
        FHE.allowThis(totalStaked);
    }

    function unstake() public {
        bool earlyExit = block.timestamp < stakeStart[msg.sender] + minStakeDuration;
        euint64 amount = stakes[msg.sender];
        euint64 penalty = FHE.asEuint64(0);

        if (earlyExit) {
            penalty = FHE.mul(amount, FHE.asEuint64(uint64(earlyExitPenaltyPercent)));
            penaltyPool = FHE.add(penaltyPool, penalty);
            FHE.allowThis(penaltyPool);
        }

        euint64 returned = FHE.sub(amount, penalty); // [arithmetic_overflow_underflow]
        euint64 penaltyScaled = FHE.mul(penalty, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        stakes[msg.sender] = FHE.asEuint64(0);
        totalStaked = FHE.sub(totalStaked, amount);
        FHE.allowThis(stakes[msg.sender]);
        FHE.allowThis(totalStaked);
        FHE.allow(returned, msg.sender);
    }

    function distributePenalties() public onlyOwner {
        // Owner can distribute penalty pool to remaining stakers
        FHE.allowThis(penaltyPool);
    }

    function allowStake(address viewer) public {
        FHE.allow(stakes[msg.sender], viewer);
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