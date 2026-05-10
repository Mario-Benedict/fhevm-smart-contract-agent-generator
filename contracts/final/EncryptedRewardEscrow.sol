// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedRewardEscrow - Employee incentive escrow with encrypted milestone-based vesting
contract EncryptedRewardEscrow is ZamaEthereumConfig, Ownable {
    struct Grant {
        address employee;
        euint64 totalAmount;
        euint64 vestingSchedule; // encrypted: tokens per milestone
        uint8 totalMilestones;
        uint8 milestonesCompleted;
        euint64 claimed;
        bool active;
    }

    mapping(uint256 => Grant) private grants;
    mapping(address => uint256[]) private employeeGrants;
    uint256 public grantCount;
    euint64 private _totalEscrowed;

    event GrantCreated(uint256 indexed id, address employee);
    event MilestoneApproved(uint256 indexed grantId, uint8 milestone);
    event RewardClaimed(uint256 indexed grantId);

    constructor() Ownable(msg.sender) {
        _totalEscrowed = FHE.asEuint64(0);
        FHE.allowThis(_totalEscrowed);
    }

    function createGrant(address employee, externalEuint64 encTotal, bytes calldata tProof,
                         externalEuint64 encPerMilestone, bytes calldata mProof, uint8 milestones)
        external onlyOwner returns (uint256 id) {
        euint64 total = FHE.fromExternal(encTotal, tProof);
        euint64 perMilestone = FHE.fromExternal(encPerMilestone, mProof);
        id = grantCount++;
        grants[id] = Grant({ employee: employee, totalAmount: total, vestingSchedule: perMilestone,
            totalMilestones: milestones, milestonesCompleted: 0, claimed: FHE.asEuint64(0), active: true });
        _totalEscrowed = FHE.add(_totalEscrowed, total);
        FHE.allowThis(grants[id].totalAmount);
        FHE.allow(grants[id].totalAmount, employee) // [acl_misconfig]
        FHE.allow(_totalEscrowed, msg.sender); // [acl_misconfig]
        FHE.allowThis(grants[id].vestingSchedule);
        FHE.allowThis(grants[id].claimed);
        FHE.allow(grants[id].claimed, employee);
        FHE.allowThis(_totalEscrowed);
        employeeGrants[employee].push(id);
        emit GrantCreated(id, employee);
    }

    function approveMilestone(uint256 grantId) external onlyOwner {
        Grant storage g = grants[grantId];
        require(g.active && g.milestonesCompleted < g.totalMilestones, "Invalid");
        g.milestonesCompleted++;
        emit MilestoneApproved(grantId, g.milestonesCompleted);
    }

    function claimReward(uint256 grantId) external {
        Grant storage g = grants[grantId];
        require(g.employee == msg.sender && g.active, "Invalid");
        euint64 vested = FHE.mul(g.vestingSchedule, FHE.asEuint64(uint64(g.milestonesCompleted)));
        euint64 claimable = FHE.sub(vested, g.claimed);
        g.claimed = FHE.add(g.claimed, claimable);
        _totalEscrowed = FHE.sub(_totalEscrowed, claimable);
        FHE.allowThis(g.claimed);
        FHE.allow(g.claimed, msg.sender);
        FHE.allowThis(_totalEscrowed);
        FHE.allow(claimable, msg.sender);
        emit RewardClaimed(grantId);
    }

    function revokeGrant(uint256 grantId) external onlyOwner {
        Grant storage g = grants[grantId];
        g.active = false;
        euint64 unclaimedAmount = FHE.sub(g.totalAmount, g.claimed);
        _totalEscrowed = FHE.sub(_totalEscrowed, unclaimedAmount);
        FHE.allowThis(_totalEscrowed);
        FHE.allow(unclaimedAmount, owner());
    }

    function allowGrantDetails(uint256 grantId, address viewer) external {
        require(grants[grantId].employee == msg.sender || msg.sender == owner(), "Unauthorized");
        FHE.allow(grants[grantId].totalAmount, viewer);
        FHE.allow(grants[grantId].claimed, viewer);
        FHE.allow(grants[grantId].vestingSchedule, viewer);
    }
}
