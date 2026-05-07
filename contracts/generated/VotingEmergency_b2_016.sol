// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingEmergency_b2_016 - Emergency governance voting with time-weighted power
contract VotingEmergency_b2_016 is ZamaEthereumConfig {
    address public admin;
    address public guardian;

    enum EmergencyState { Normal, EmergencyDeclared, Resolved }
    EmergencyState public state;

    euint32 private approvalVotes;
    euint32 private rejectionVotes;
    mapping(address => bool) public hasVoted;
    mapping(address => euint32) public stakingPower;

    uint256 public emergencyStartTime;
    uint256 public constant VOTING_WINDOW = 6 hours;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Not guardian");
        _;
    }

    constructor(address _guardian) {
        admin = msg.sender;
        guardian = _guardian;
        approvalVotes = FHE.asEuint32(0);
        rejectionVotes = FHE.asEuint32(0);
        FHE.allowThis(approvalVotes);
        FHE.allowThis(rejectionVotes);
    }

    function grantStakingPower(address user, externalEuint32 powerStr, bytes calldata proof) public onlyAdmin {
        euint32 power = FHE.fromExternal(powerStr, proof);
        stakingPower[user] = power;
        FHE.allowThis(stakingPower[user]);
    }

    function declareEmergency() public onlyGuardian {
        require(state == EmergencyState.Normal, "Not in normal state");
        state = EmergencyState.EmergencyDeclared;
        emergencyStartTime = block.timestamp;
    }

    function voteOnEmergency(bool approve, externalEuint32 powerStr, bytes calldata proof) public {
        require(state == EmergencyState.EmergencyDeclared, "No active emergency");
        require(block.timestamp <= emergencyStartTime + VOTING_WINDOW, "Window expired");
        require(!hasVoted[msg.sender], "Already voted");
        euint32 power = FHE.fromExternal(powerStr, proof);
        hasVoted[msg.sender] = true;
        if (approve) {
            approvalVotes = FHE.add(approvalVotes, power);
            FHE.allowThis(approvalVotes);
        } else {
            rejectionVotes = FHE.add(rejectionVotes, power);
            FHE.allowThis(rejectionVotes);
        }
    }

    function resolve() public onlyAdmin {
        state = EmergencyState.Resolved;
    }

    function allowResults(address viewer) public onlyAdmin {
        FHE.allow(approvalVotes, viewer);
        FHE.allow(rejectionVotes, viewer);
    }
}
