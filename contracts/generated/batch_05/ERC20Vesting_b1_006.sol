// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Vesting_b1_006 - Confidential ERC20 with linear vesting
contract ERC20Vesting_b1_006 is ZamaEthereumConfig {
    string public name = "Vesting Token";
    string public symbol = "VSTK";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    struct VestingSchedule {
        euint64 totalAmount;
        uint256 startTime;
        uint256 duration;
        euint64 released;
    }

    mapping(address => VestingSchedule) private vestings;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(10_000_000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function createVesting(
        address beneficiary,
        externalEuint64 amountStr,
        bytes calldata proof,
        uint256 durationSeconds
    ) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        vestings[beneficiary] = VestingSchedule({
            totalAmount: amount,
            startTime: block.timestamp,
            duration: durationSeconds,
            released: FHE.asEuint64(0)
        });
        FHE.allowThis(vestings[beneficiary].totalAmount);
        FHE.allowThis(vestings[beneficiary].released);
    }

    function release() public {
        VestingSchedule storage v = vestings[msg.sender];
        require(v.startTime > 0, "No vesting");

        uint256 elapsed = block.timestamp - v.startTime;
        uint256 pct = elapsed >= v.duration ? 100 : (elapsed * 100) / v.duration;

        euint64 vested = FHE.mul(v.totalAmount, FHE.asEuint64(uint64(pct)));
        // vested is in percent-units; divide by 100
        euint64 releasable = FHE.sub(vested, FHE.mul(v.released, FHE.asEuint64(100)));
        ebool hasReleasable = FHE.gt(releasable, FHE.asEuint64(0));
        euint64 payout = FHE.select(hasReleasable, releasable, FHE.asEuint64(0));

        v.released = FHE.add(v.released, FHE.asEuint64(uint64(pct)));
        balances[msg.sender] = FHE.add(balances[msg.sender], payout);
        FHE.allowThis(v.released);
        FHE.allowThis(balances[msg.sender]);
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
