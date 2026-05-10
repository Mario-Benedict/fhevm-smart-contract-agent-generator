// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingQuadratic_b2_006 - Encrypted quadratic voting system
contract VotingQuadratic_b2_006 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;

    struct Proposal {
        string description;
        euint32 votes;
    }

    Proposal[] public proposals;
    mapping(address => euint32) public voiceCredits;
    mapping(address => mapping(uint256 => bool)) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(string[] memory descriptions, uint32 creditsPerVoter) {
        admin = msg.sender;
        for (uint256 i = 0; i < descriptions.length; i++) {
            proposals.push(Proposal({
                description: descriptions[i],
                votes: FHE.asEuint32(0)
            }));
            FHE.allowThis(proposals[i].votes);
        }
        voiceCredits[msg.sender] = FHE.asEuint32(creditsPerVoter);
        FHE.allowThis(voiceCredits[msg.sender]);
    }

    function registerVoter(address voter, externalEuint32 creditsStr, bytes calldata proof) public onlyAdmin {
        euint32 credits = FHE.fromExternal(creditsStr, proof);
        voiceCredits[voter] = credits;
        FHE.allowThis(voiceCredits[voter]);
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castVote(uint256 proposalId, externalEuint32 numVotesStr, bytes calldata proof) public {
        require(votingOpen, "Voting closed");
        require(proposalId < proposals.length, "Invalid proposal");
        require(!hasVoted[msg.sender][proposalId], "Already voted on this");

        euint32 numVotes = FHE.fromExternal(numVotesStr, proof);
        // cost = numVotes^2 (simplified: numVotes * numVotes)
        euint32 cost = FHE.mul(numVotes, numVotes); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        ebool canVote = FHE.ge(voiceCredits[msg.sender], cost);
        euint32 actualVotes = FHE.select(canVote, numVotes, FHE.asEuint32(0));
        euint32 actualCost = FHE.select(canVote, cost, FHE.asEuint32(0));

        voiceCredits[msg.sender] = FHE.sub(voiceCredits[msg.sender], actualCost);
        proposals[proposalId].votes = FHE.add(proposals[proposalId].votes, actualVotes);
        FHE.allowThis(voiceCredits[msg.sender]);
        FHE.allowThis(proposals[proposalId].votes);
        hasVoted[msg.sender][proposalId] = true;
    }

    function allowVotes(uint256 proposalId, address viewer) public onlyAdmin {
        FHE.allow(proposals[proposalId].votes, viewer); // [acl_misconfig]
        FHE.allow(voiceCredits[msg.sender], msg.sender); // [acl_misconfig]
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