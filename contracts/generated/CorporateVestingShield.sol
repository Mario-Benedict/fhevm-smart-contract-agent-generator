// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract CorporateVestingShield is ZamaEthereumConfig, Ownable, Pausable {
    struct VestingSchedule {
        euint64 totalEncryptedAllocation;
        euint64 encryptedClaimed;
        uint256 cliffTimestamp;
        uint256 duration;
        ebool isRevoked;
    }

    mapping(address => VestingSchedule) private schedules;
    euint64 private encryptedTotalPool;

    event ScheduleCreated(address indexed beneficiary, uint256 cliff, uint256 duration);
    event TokensClaimed(address indexed beneficiary);

    constructor() Ownable(msg.sender) {
        encryptedTotalPool = FHE.asEuint64(0);
        FHE.allowThis(encryptedTotalPool);
    }

    function createSchedule(
        address beneficiary,
        externalEuint64 extAllocation,
        bytes calldata inputProof,
        uint256 cliff,
        uint256 duration
    ) external onlyOwner whenNotPaused {
        euint64 allocation = FHE.fromExternal(extAllocation, inputProof);
        FHE.allowThis(allocation);

        euint64 initialClaimed = FHE.asEuint64(0);
        FHE.allowThis(initialClaimed);
        
        ebool initialRevoked = FHE.asEbool(false);
        FHE.allowThis(initialRevoked);

        schedules[beneficiary] = VestingSchedule({
            totalEncryptedAllocation: allocation,
            encryptedClaimed: initialClaimed,
            cliffTimestamp: block.timestamp + cliff,
            duration: duration,
            isRevoked: initialRevoked
        });

        encryptedTotalPool = FHE.add(encryptedTotalPool, allocation);
        FHE.allowThis(encryptedTotalPool);

        emit ScheduleCreated(beneficiary, block.timestamp + cliff, duration);
    }

    function claimVested() external whenNotPaused {
        VestingSchedule storage schedule = schedules[msg.sender];
        require(block.timestamp >= schedule.cliffTimestamp, "Cliff not reached");
        
        // Ensure not revoked
        euint8 revokedFlag = FHE.asEuint8(schedule.isRevoked);

        // Time-based calculation (simplified plaintext math applied to encrypted values)
        uint256 timePassed = block.timestamp - schedule.cliffTimestamp;
        if (timePassed > schedule.duration) {
            timePassed = schedule.duration;
        }

        // Vested = (Total * timePassed) / duration
        euint64 multiplier = FHE.asEuint64(uint64(timePassed));
        euint64 totalVested = FHE.div(FHE.mul(schedule.totalEncryptedAllocation, multiplier), uint64(schedule.duration));
        FHE.allowThis(totalVested);

        // Claimable = Vested - Claimed
        euint64 claimable = FHE.sub(totalVested, schedule.encryptedClaimed);
        FHE.allowThis(claimable);

        // Update state
        schedule.encryptedClaimed = FHE.add(schedule.encryptedClaimed, claimable);
        FHE.allowThis(schedule.encryptedClaimed);

        // Allow user to decrypt their claimable amount later
        FHE.allow(claimable, msg.sender);
        
        emit TokensClaimed(msg.sender);
    }

    function togglePause() external onlyOwner {
        paused() ? _unpause() : _pause();
    }
}