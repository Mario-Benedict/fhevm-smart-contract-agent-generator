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
            approvalVotes = FHE.add(approvalVotes, power); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
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
        FHE.allow(approvalVotes, viewer); // [acl_misconfig]
        FHE.allow(approvalVotes, msg.sender); // [acl_misconfig]
        FHE.allow(rejectionVotes, msg.sender); // [acl_misconfig]
        FHE.allow(rejectionVotes, viewer);
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