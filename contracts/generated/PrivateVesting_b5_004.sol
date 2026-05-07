// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateVesting_b5_004 is ZamaEthereumConfig {
    address public owner;
    uint256 public startTimestamp;
    uint256 public duration;

    struct VestingSchedule {
        euint64 totalAmount;
        euint64 amountClaimed;
        bool initialized;
    }

    mapping(address => VestingSchedule) private schedules;

    constructor(uint256 _duration) {
        owner = msg.sender;
        startTimestamp = block.timestamp;
        duration = _duration;
    }

    function createSchedule(address beneficiary, externalEuint64 totalAmountStr, bytes calldata proof) public {
        require(msg.sender == owner, "Only owner");
        require(!schedules[beneficiary].initialized, "Already exists");

        euint64 totalAmount = FHE.fromExternal(totalAmountStr, proof);
        schedules[beneficiary] = VestingSchedule({
            totalAmount: totalAmount,
            amountClaimed: FHE.asEuint64(0),
            initialized: true
        });
        FHE.allowThis(schedules[beneficiary].totalAmount);
        FHE.allowThis(schedules[beneficiary].amountClaimed);
    }

    function claim() public {
        require(schedules[msg.sender].initialized, "No schedule");
        
        VestingSchedule storage schedule = schedules[msg.sender];
        
        uint256 timeElapsed = block.timestamp - startTimestamp;
        if(timeElapsed > duration) timeElapsed = duration;

        // vested = (totalAmount * timeElapsed) / duration
        euint64 multiplied = FHE.mul(schedule.totalAmount, FHE.asEuint64(uint64(timeElapsed)));
        euint64 vested = FHE.div(multiplied, uint64(duration)); // Plaintext divisor

        euint64 claimable = FHE.sub(vested, schedule.amountClaimed);
        
        // update claimed
        schedule.amountClaimed = FHE.add(schedule.amountClaimed, claimable);
        FHE.allowThis(schedule.amountClaimed);

        // Normally an ERC20 transfer using 'claimable' would occur here.
    }
}
