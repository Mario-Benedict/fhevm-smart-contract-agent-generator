// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingBoard_b2_012 - Board election voting with encrypted seat tallies
contract VotingBoard_b2_012 is ZamaEthereumConfig {
    address public admin;
    bool public electionOpen;
    uint8 public seatsAvailable;

    struct Candidate {
        string name;
        euint32 votes;
        bool registered;
    }

    mapping(address => Candidate) public candidates;
    address[] public candidateList;
    mapping(address => bool) public hasVoted;
    mapping(address => bool) public isVoter;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint8 _seats) {
        admin = msg.sender;
        seatsAvailable = _seats;
    }

    function registerCandidate(address candidate, string calldata name) public onlyAdmin {
        candidates[candidate] = Candidate({ name: name, votes: FHE.asEuint32(0), registered: true });
        FHE.allowThis(candidates[candidate].votes);
        candidateList.push(candidate);
    }

    function registerVoter(address voter) public onlyAdmin {
        isVoter[voter] = true;
    }

    function openElection() public onlyAdmin { electionOpen = true; }
    function closeElection() public onlyAdmin { electionOpen = false; }

    function voteForCandidate(address candidate) public {
        require(electionOpen, "Election not open");
        require(isVoter[msg.sender], "Not registered voter");
        require(!hasVoted[msg.sender], "Already voted");
        require(candidates[candidate].registered, "Not a candidate");
        hasVoted[msg.sender] = true;
        candidates[candidate].votes = FHE.add(candidates[candidate].votes, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(candidates[candidate].votes);
    }

    function allowCandidateVotes(address candidate, address viewer) public onlyAdmin {
        FHE.allow(candidates[candidate].votes, viewer); // [acl_misconfig]
        FHE.allow(candidates[candidate].votes, msg.sender); // [acl_misconfig]
    }

    function getCandidateCount() public view returns (uint256) {
        return candidateList.length;
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