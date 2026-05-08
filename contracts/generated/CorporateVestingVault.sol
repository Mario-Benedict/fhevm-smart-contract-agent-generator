// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CorporateVestingVault is ZamaEthereumConfig, Ownable {
    IERC20 public immutable corporateToken;

    struct VestingSchedule {
        euint64 encryptedTotalAllocation;
        euint64 encryptedClaimedAmount;
        uint256 cliff;
        uint256 duration;
        bool isRevocable;
        bool isRevoked;
        bool exists;
    }

    mapping(address => VestingSchedule) private schedules;
    euint64 private totalEncryptedLiabilities;

    constructor(address _corporateToken) Ownable(msg.sender) {
        corporateToken = IERC20(_corporateToken);
        totalEncryptedLiabilities = FHE.asEuint64(0);
        FHE.allowThis(totalEncryptedLiabilities);
    }

    function grantVesting(
        address employee,
        externalEuint64 memory extAllocation,
        bytes calldata proof,
        uint256 cliffDuration,
        uint256 vestingDuration,
        bool revocable
    ) external onlyOwner {
        require(!schedules[employee].exists, "Schedule exists");

        euint64 allocation = FHE.fromExternal(extAllocation, proof);
        euint64 claimed = FHE.asEuint64(0);
        
        FHE.allowThis(allocation);
        FHE.allowThis(claimed);

        schedules[employee] = VestingSchedule({
            encryptedTotalAllocation: allocation,
            encryptedClaimedAmount: claimed,
            cliff: block.timestamp + cliffDuration,
            duration: vestingDuration,
            isRevocable: revocable,
            isRevoked: false,
            exists: true
        });

        totalEncryptedLiabilities = FHE.add(totalEncryptedLiabilities, allocation);
        FHE.allowThis(totalEncryptedLiabilities);
    }

    function revokeVesting(address employee) external onlyOwner {
        require(schedules[employee].exists, "No schedule");
        require(schedules[employee].isRevocable, "Not revocable");
        schedules[employee].isRevoked = true;
    }

    function claimVestedTokens(externalEuint64 memory extRequest, bytes calldata proof) external {
        VestingSchedule storage schedule = schedules[msg.sender];
        require(schedule.exists, "No schedule");
        require(block.timestamp >= schedule.cliff, "Cliff not reached");
        require(!schedule.isRevoked, "Schedule revoked");

        euint64 requestAmount = FHE.fromExternal(extRequest, proof);
        FHE.allowThis(requestAmount);

        uint256 timePassed = block.timestamp - (schedule.cliff - (schedule.cliff - block.timestamp)); // Handle cliff offset
        if (timePassed > schedule.duration) {
            timePassed = schedule.duration;
        }

        euint64 encTimePassed = FHE.asEuint64(timePassed);
        euint64 totalVested = FHE.div(FHE.mul(schedule.encryptedTotalAllocation, encTimePassed), schedule.duration);
        FHE.allowThis(totalVested);

        euint64 claimable = FHE.sub(totalVested, schedule.encryptedClaimedAmount);
        FHE.allowThis(claimable);

        ebool canClaim = FHE.ge(claimable, requestAmount);
        FHE.req(canClaim);

        schedule.encryptedClaimedAmount = FHE.add(schedule.encryptedClaimedAmount, requestAmount);
        FHE.allowThis(schedule.encryptedClaimedAmount);

        totalEncryptedLiabilities = FHE.sub(totalEncryptedLiabilities, requestAmount);
        FHE.allowThis(totalEncryptedLiabilities);

        uint64 decryptedTransfer = FHE.decrypt(requestAmount);
        require(corporateToken.transfer(msg.sender, decryptedTransfer), "Transfer failed");
    }
}