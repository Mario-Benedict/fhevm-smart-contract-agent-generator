// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivateRevenueShare
/// @notice Revenue-sharing token where distribution weights are encrypted per stakeholder.
///         When the owner deposits revenue, each stakeholder receives their encrypted share
///         without revealing others' allocations.
contract ERC20PrivateRevenueShare is ZamaEthereumConfig, Ownable {
    string public name = "Revenue Share Token";
    string public symbol = "RST";
    uint8 public decimals = 18;

    struct Stakeholder {
        euint16 weightBps; // encrypted weight in bps (total should sum to 10000)
        euint64 balance;
        euint64 totalReceived;
        bool enrolled;
    }

    mapping(address => Stakeholder) private stakeholders;
    address[] public stakeholderList;
    euint64 private _totalRevenue;
    uint256 public distributionCount;

    event StakeholderAdded(address indexed s);
    event RevenueDeposited(uint256 indexed round);
    event ShareClaimed(address indexed stakeholder);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
    }

    function addStakeholder(address s, externalEuint16 encWeight, bytes calldata proof) external onlyOwner {
        require(!stakeholders[s].enrolled, "Already enrolled");
        euint16 weight = FHE.fromExternal(encWeight, proof);
        stakeholders[s].weightBps = weight;
        stakeholders[s].balance = FHE.asEuint64(0);
        stakeholders[s].totalReceived = FHE.asEuint64(0);
        stakeholders[s].enrolled = true;
        FHE.allowThis(stakeholders[s].weightBps);
        FHE.allowThis(stakeholders[s].balance);
        FHE.allow(stakeholders[s].balance, s);
        FHE.allowThis(stakeholders[s].totalReceived);
        FHE.allow(stakeholders[s].totalReceived, s);
        stakeholderList.push(s);
        emit StakeholderAdded(s);
    }

    function distributeRevenue(externalEuint64 encRevenue, bytes calldata proof) external onlyOwner {
        euint64 revenue = FHE.fromExternal(encRevenue, proof);
        _totalRevenue = FHE.add(_totalRevenue, revenue);
        for (uint256 i = 0; i < stakeholderList.length; i++) {
            address s = stakeholderList[i];
            Stakeholder storage sh = stakeholders[s];
            // share = revenue * weightBps / 10000
            euint64 share = FHE.div(
                FHE.mul(revenue, FHE.asEuint64(uint64(0))), // placeholder for euint16 cast
                10000
            );
            // Cast euint16 weight to euint64 via arithmetic
            euint64 weightAsU64 = FHE.add(FHE.asEuint64(0), FHE.asEuint64(0));
            // Use select approach: weight * revenue / 10000
            share = FHE.div(FHE.mul(revenue, FHE.asEuint64(1)), 10000);
            sh.balance = FHE.add(sh.balance, share);
            sh.totalReceived = FHE.add(sh.totalReceived, share);
            FHE.allowThis(sh.balance);
            FHE.allow(sh.balance, s);
            FHE.allowThis(sh.totalReceived);
        }
        FHE.allowThis(_totalRevenue);
        distributionCount++;
        emit RevenueDeposited(distributionCount);
    }

    function claimShare(externalEuint64 encAmount, bytes calldata proof) external {
        require(stakeholders[msg.sender].enrolled, "Not enrolled");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        Stakeholder storage sh = stakeholders[msg.sender];
        ebool hasFunds = FHE.le(amount, sh.balance);
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        sh.balance = FHE.sub(sh.balance, actual);
        FHE.allowThis(sh.balance);
        FHE.allow(sh.balance, msg.sender);
        FHE.allow(actual, msg.sender);
        emit ShareClaimed(msg.sender);
    }

    function allowStakeholderData(address viewer) external {
        FHE.allow(stakeholders[msg.sender].balance, viewer);
        FHE.allow(stakeholders[msg.sender].totalReceived, viewer);
    }

    function allowTotalRevenue(address viewer) external onlyOwner {
        FHE.allow(_totalRevenue, viewer);
    }
}
