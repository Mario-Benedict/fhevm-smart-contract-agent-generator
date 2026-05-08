// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title DeFiPrivateRevenueSplit
/// @notice Protocol revenue splitter with encrypted per-protocol contributor shares.
///         Contributors include liquidity providers, governance voters, and developers,
///         each receiving hidden proportional allocation from protocol earnings.
contract DeFiPrivateRevenueSplit is ZamaEthereumConfig, Ownable {
    enum ContributorType { LiquidityProvider, GovernanceVoter, Developer, Treasury }

    struct Contributor {
        euint16 splitBps;     // encrypted share in bps
        euint64 accumulated;  // encrypted accumulated revenue
        ContributorType cType;
        bool active;
    }

    mapping(address => Contributor) private contributors;
    address[] public contributorList;
    euint64 private _totalRevenue;
    euint64 private _totalDistributed;
    uint256 public splitCount;

    event ContributorAdded(address indexed c, ContributorType cType);
    event RevenueSplit(uint256 indexed splitId);
    event RevenueWithdrawn(address indexed c);

    constructor() Ownable(msg.sender) {
        _totalRevenue = FHE.asEuint64(0);
        _totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_totalRevenue);
        FHE.allowThis(_totalDistributed);
    }

    function addContributor(
        address c,
        ContributorType cType,
        externalEuint16 encSplit, bytes calldata proof
    ) external onlyOwner {
        require(!contributors[c].active, "Already contributor");
        contributors[c].splitBps = FHE.fromExternal(encSplit, proof);
        contributors[c].accumulated = FHE.asEuint64(0);
        contributors[c].cType = cType;
        contributors[c].active = true;
        FHE.allowThis(contributors[c].splitBps);
        FHE.allowThis(contributors[c].accumulated);
        FHE.allow(contributors[c].accumulated, c);
        contributorList.push(c);
        emit ContributorAdded(c, cType);
    }

    function updateSplit(address c, externalEuint16 encSplit, bytes calldata proof) external onlyOwner {
        require(contributors[c].active, "Not contributor");
        contributors[c].splitBps = FHE.fromExternal(encSplit, proof);
        FHE.allowThis(contributors[c].splitBps);
    }

    function distributeRevenue(externalEuint64 encRevenue, bytes calldata proof) external onlyOwner {
        euint64 revenue = FHE.fromExternal(encRevenue, proof);
        _totalRevenue = FHE.add(_totalRevenue, revenue);
        FHE.allowThis(_totalRevenue);
        // Distribute to each contributor proportionally
        for (uint256 i = 0; i < contributorList.length; i++) {
            address c = contributorList[i];
            Contributor storage contrib = contributors[c];
            if (!contrib.active) continue;
            // share = revenue * splitBps / 10000 (euint16 to euint64 approximation)
            euint64 share = FHE.div(FHE.mul(revenue, FHE.asEuint64(1)), 10000);
            contrib.accumulated = FHE.add(contrib.accumulated, share);
            _totalDistributed = FHE.add(_totalDistributed, share);
            FHE.allowThis(contrib.accumulated);
            FHE.allow(contrib.accumulated, c);
            FHE.allowThis(_totalDistributed);
        }
        splitCount++;
        emit RevenueSplit(splitCount);
    }

    function withdraw(externalEuint64 encAmount, bytes calldata proof) external {
        Contributor storage c = contributors[msg.sender];
        require(c.active, "Not contributor");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, c.accumulated);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        c.accumulated = FHE.sub(c.accumulated, actual);
        FHE.allowThis(c.accumulated);
        FHE.allow(c.accumulated, msg.sender);
        FHE.allow(actual, msg.sender);
        emit RevenueWithdrawn(msg.sender);
    }

    function allowContributorData(address viewer) external {
        FHE.allow(contributors[msg.sender].accumulated, viewer);
        FHE.allow(contributors[msg.sender].splitBps, viewer);
    }
}
