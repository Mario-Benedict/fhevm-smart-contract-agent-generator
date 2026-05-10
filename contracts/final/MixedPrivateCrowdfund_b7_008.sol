// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedPrivateCrowdfund_b7_008 - Private crowdfunding with encrypted contributions
contract MixedPrivateCrowdfund_b7_008 is ZamaEthereumConfig {
    address public creator;
    string public campaignTitle;
    euint64 private goal;
    euint64 private totalRaised;
    uint256 public deadline;
    bool public goalMet;
    bool public fundsWithdrawn;

    mapping(address => euint64) private contributions;
    address[] public contributors;

    modifier onlyCreator() {
        require(msg.sender == creator, "Not creator");
        _;
    }

    constructor(
        string memory title,
        externalEuint64 goalStr,
        bytes memory goalProof,
        uint256 durationDays
    ) {
        creator = msg.sender;
        campaignTitle = title;
        goal = FHE.fromExternal(goalStr, goalProof);
        deadline = block.timestamp + durationDays * 1 days;
        totalRaised = FHE.asEuint64(0);
        FHE.allowThis(goal);
        FHE.allowThis(totalRaised);
    }

    function contribute(externalEuint64 amountStr, bytes calldata proof) public {
        require(block.timestamp < deadline, "Campaign ended");
        require(!goalMet, "Goal already met");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        if (!FHE.isInitialized(contributions[msg.sender])) {
            contributors.push(msg.sender);
        }
        contributions[msg.sender] = FHE.add(contributions[msg.sender], amount); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        totalRaised = FHE.add(totalRaised, amount);
        FHE.allowThis(contributions[msg.sender]);
        FHE.allowThis(totalRaised);
        // Check if goal is met
        goalMet = FHE.isInitialized(FHE.ge(totalRaised, goal));
    }

    function withdrawFunds() public onlyCreator {
        require(goalMet, "Goal not met");
        require(!fundsWithdrawn, "Already withdrawn");
        fundsWithdrawn = true;
        FHE.allow(totalRaised, creator);
    }

    function refund() public {
        require(!goalMet && block.timestamp >= deadline, "Cannot refund");
        euint64 contribution = contributions[msg.sender];
        contributions[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(contributions[msg.sender]);
        FHE.allow(contribution, msg.sender);
    }

    function allowTotalRaised(address viewer) public onlyCreator {
        FHE.allow(totalRaised, viewer);
        FHE.allow(goal, viewer);
    }

    function getContributorCount() public view returns (uint256) {
        return contributors.length;
    }
}
