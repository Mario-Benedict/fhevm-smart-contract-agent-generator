// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingClimatePolicy
/// @notice Climate policy referendum where each voter's encrypted impact score (based on
///         their sector: agriculture, industry, transport) influences the weighted outcome.
contract VotingClimatePolicy is ZamaEthereumConfig, Ownable {
    enum Sector { Agriculture, Industry, Transport, Residential, Energy }

    struct Voter {
        euint8 sectorImpactWeight; // encrypted 1-10 weight based on sector
        Sector sector;
        bool registered;
        mapping(uint256 => bool) voted;
    }

    struct Policy {
        string name;
        euint32 weightedYes;
        euint32 weightedNo;
        uint256 deadline;
        bool finalized;
        bool passed;
    }

    mapping(address => Voter) private voters;
    address[] public voterList;
    mapping(uint256 => Policy) private policies;
    uint256 public policyCount;

    event VoterRegistered(address indexed v, Sector sector);
    event PolicyProposed(uint256 indexed id, string name);
    event PolicyVote(uint256 indexed id, address voter);
    event PolicyPassed(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function registerVoter(
        address v, Sector sector,
        externalEuint8 encWeight, bytes calldata proof
    ) external onlyOwner {
        voters[v].sectorImpactWeight = FHE.fromExternal(encWeight, proof);
        voters[v].sector = sector;
        voters[v].registered = true;
        FHE.allowThis(voters[v].sectorImpactWeight);
        voterList.push(v);
        emit VoterRegistered(v, sector);
    }

    function proposePolicy(string calldata name, uint256 daysOpen) external onlyOwner returns (uint256 id) {
        id = policyCount++;
        policies[id].name = name;
        policies[id].weightedYes = FHE.asEuint32(0);
        policies[id].weightedNo = FHE.asEuint32(0);
        policies[id].deadline = block.timestamp + daysOpen * 1 days;
        FHE.allowThis(policies[id].weightedYes);
        FHE.allowThis(policies[id].weightedNo);
        emit PolicyProposed(id, name);
    }

    function vote(uint256 policyId, bool voteYes) external {
        Voter storage v = voters[msg.sender];
        require(v.registered, "Not registered");
        Policy storage p = policies[policyId];
        require(!p.finalized && block.timestamp <= p.deadline, "Closed");
        require(!v.voted[policyId], "Already voted");
        v.voted[policyId] = true;

        // Cast euint8 weight to euint32 for addition
        euint32 weight = FHE.asEuint32(0); // placeholder; use the voter's weight via add
        // Add weight to appropriate bucket
        if (voteYes) {
            p.weightedYes = FHE.add(p.weightedYes, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(p.weightedYes);
        } else {
            p.weightedNo = FHE.add(p.weightedNo, FHE.asEuint32(1));
            FHE.allowThis(p.weightedNo);
        }
        emit PolicyVote(policyId, msg.sender);
    }

    function finalizePolicy(uint256 policyId) external onlyOwner {
        Policy storage p = policies[policyId];
        require(!p.finalized, "Already finalized");
        p.finalized = true;
        ebool passed = FHE.gt(p.weightedYes, p.weightedNo);
        p.passed = FHE.isInitialized(passed);
        if (p.passed) emit PolicyPassed(policyId);
    }

    function allowPolicyData(uint256 policyId, address viewer) external onlyOwner {
        FHE.allow(policies[policyId].weightedYes, viewer); // [acl_misconfig]
        FHE.allow(_pendingSettlements[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(policies[policyId].weightedNo, viewer);
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