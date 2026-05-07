// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingFutarchyMarket_c2_029 - Futarchy: policy chosen based on market prediction outcome
contract VotingFutarchyMarket_c2_029 is ZamaEthereumConfig, Ownable {
    struct Policy {
        string description;
        euint64 betPool;
        euint64 againstPool;
        bool enacted;
    }

    Policy[] public policies;
    mapping(address => mapping(uint256 => euint64)) private _betFor;
    mapping(address => mapping(uint256 => euint64)) private _betAgainst;
    mapping(address => euint64) private _tokenBalance;
    bool public marketOpen;

    constructor() Ownable(msg.sender) {}

    function mintTokens(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _tokenBalance[to] = FHE.add(_tokenBalance[to], amount);
        FHE.allowThis(_tokenBalance[to]);
        FHE.allow(_tokenBalance[to], to);
    }

    function proposePolicy(string calldata desc) external onlyOwner returns (uint256 id) {
        id = policies.length;
        policies.push(Policy({ description: desc, betPool: FHE.asEuint64(0), againstPool: FHE.asEuint64(0), enacted: false }));
        FHE.allowThis(policies[id].betPool);
        FHE.allowThis(policies[id].againstPool);
    }

    function betOnPolicy(uint256 policyId, bool support, externalEuint64 encAmount, bytes calldata proof) external {
        require(marketOpen, "Market closed");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _tokenBalance[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _tokenBalance[msg.sender] = FHE.sub(_tokenBalance[msg.sender], actual);
        FHE.allowThis(_tokenBalance[msg.sender]);
        FHE.allow(_tokenBalance[msg.sender], msg.sender);
        if (support) {
            _betFor[msg.sender][policyId] = FHE.add(_betFor[msg.sender][policyId], actual);
            policies[policyId].betPool = FHE.add(policies[policyId].betPool, actual);
            FHE.allowThis(_betFor[msg.sender][policyId]);
            FHE.allowThis(policies[policyId].betPool);
        } else {
            _betAgainst[msg.sender][policyId] = FHE.add(_betAgainst[msg.sender][policyId], actual);
            policies[policyId].againstPool = FHE.add(policies[policyId].againstPool, actual);
            FHE.allowThis(_betAgainst[msg.sender][policyId]);
            FHE.allowThis(policies[policyId].againstPool);
        }
    }

    function enactPolicy(uint256 policyId) external onlyOwner {
        policies[policyId].enacted = true;
    }

    function claimWinnings(uint256 policyId) external {
        Policy storage p = policies[policyId];
        euint64 myBet = p.enacted ? _betFor[msg.sender][policyId] : _betAgainst[msg.sender][policyId];
        // euint64 winPool = p.enacted ? p.betPool : p.againstPool;
        euint64 totalPool = FHE.add(p.betPool, p.againstPool);
        ebool hasBet = FHE.gt(myBet, FHE.asEuint64(0));
        // Plaintext divisor needed for FHE.div in current versions
        euint64 payout = FHE.select(hasBet, FHE.div(FHE.mul(myBet, totalPool), 100), FHE.asEuint64(0));
        FHE.allow(payout, msg.sender);
    }

    function openMarket() external onlyOwner { marketOpen = true; }
    function closeMarket() external onlyOwner { marketOpen = false; }

    function allowPolicyData(uint256 policyId, address viewer) external onlyOwner {
        FHE.allow(policies[policyId].betPool, viewer);
        FHE.allow(policies[policyId].againstPool, viewer);
    }
}
