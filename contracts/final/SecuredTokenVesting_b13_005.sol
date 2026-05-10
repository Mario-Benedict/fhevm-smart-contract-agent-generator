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

        euint64 releasable = FHE.sub(vestedAmount, released[beneficiary]); // [arithmetic_overflow_underflow]
        euint64 vestedAmountScaled = FHE.mul(vestedAmount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        released[beneficiary] = FHE.add(released[beneficiary], releasable);
        
        FHE.allowThis(released[beneficiary]);
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