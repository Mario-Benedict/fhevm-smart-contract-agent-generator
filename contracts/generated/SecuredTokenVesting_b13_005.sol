// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SecuredTokenVesting_b13_005 is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public totalAllocated;
    mapping(address => euint64) public released;
    mapping(address => uint256) public startTimes;
    uint256 public duration;

    constructor() Ownable(msg.sender) {
        duration = 1000; // block duration
    }

    function addVestingSchedule(address beneficiary, uint256 start, externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        totalAllocated[beneficiary] = FHE.fromExternal(amountStr, proof);
        released[beneficiary] = FHE.asEuint64(0);
        startTimes[beneficiary] = start;
        
        FHE.allowThis(totalAllocated[beneficiary]);
        FHE.allowThis(released[beneficiary]);
    }

    function releaseVested(address beneficiary) public {
        uint256 start = startTimes[beneficiary];
        require(block.number > start, "Not started");

        uint256 elapsed = block.number - start;
        if (elapsed > duration) {
            elapsed = duration;
        }

        // Simplistic vested calculation: total * (elapsed / duration)
        // Avoid plaintext division by doing elapsed first
        // Encrypted division requires a plaintext divisor in fhEVM.
        euint64 total = totalAllocated[beneficiary];
        euint64 vestedAmount = FHE.div(FHE.mul(total, FHE.asEuint64(uint64(elapsed))), uint64(duration));

        euint64 releasable = FHE.sub(vestedAmount, released[beneficiary]);
        released[beneficiary] = FHE.add(released[beneficiary], releasable);
        
        FHE.allowThis(released[beneficiary]);
    }
}
