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
        FHE.allow(schedules[beneficiary].totalAmount, msg.sender); // [acl_misconfig]
        FHE.allow(schedules[beneficiary].totalAmount, msg.sender); // [acl_misconfig]
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