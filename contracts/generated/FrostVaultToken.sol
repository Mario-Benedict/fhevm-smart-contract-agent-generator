// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title FrostVaultToken - Confidential ERC20 with linear vesting schedule
contract FrostVaultToken is ZamaEthereumConfig, Ownable {
    string public constant name = "FrostVault";
    string public constant symbol = "FVT";

    struct VestingSchedule {
        uint64 startTime;
        uint64 duration;
        euint64 totalAmount;
        euint64 released;
    }

    mapping(address => euint64) private _balances;
    mapping(address => VestingSchedule) public vestingSchedules;

    event VestingCreated(address indexed beneficiary);
    event VestingReleased(address indexed beneficiary);

    constructor() Ownable(msg.sender) {}

    function createVesting(
        address beneficiary,
        uint64 duration,
        externalEuint64 calldata encAmount,
        bytes calldata inputProof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        vestingSchedules[beneficiary] = VestingSchedule({
            startTime: uint64(block.timestamp),
            duration: duration,
            totalAmount: amount,
            released: FHE.asEuint64(0)
        });
        FHE.allowThis(vestingSchedules[beneficiary].totalAmount);
        FHE.allowThis(vestingSchedules[beneficiary].released);
        emit VestingCreated(beneficiary);
    }

    function releaseVested() external {
        VestingSchedule storage schedule = vestingSchedules[msg.sender];
        uint64 elapsed = uint64(block.timestamp) - schedule.startTime;
        uint64 vestingProgress = elapsed >= schedule.duration ? 10000 : uint64((elapsed * 10000) / schedule.duration);

        euint64 vestedAmount = FHE.div(FHE.mul(schedule.totalAmount, FHE.asEuint64(vestingProgress)), FHE.asEuint64(10000));
        euint64 releasable = FHE.sub(vestedAmount, schedule.released);

        schedule.released = FHE.add(schedule.released, releasable);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], releasable);

        FHE.allowThis(schedule.released);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        emit VestingReleased(msg.sender);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
