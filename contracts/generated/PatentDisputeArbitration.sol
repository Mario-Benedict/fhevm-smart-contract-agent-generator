// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PatentDisputeArbitration - Encrypted arbitrator panel voting on patent dispute cases
contract PatentDisputeArbitration is ZamaEthereumConfig, Ownable {
    struct DisputeCase {
        string patentId;
        address claimant;
        address respondent;
        euint8 arbitratorVotesForClaimant;
        euint8 arbitratorVotesForRespondent;
        euint8 totalArbitrators;
        uint256 votingDeadline;
        bool resolved;
        bool claimantWon;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => DisputeCase) public cases;
    mapping(address => bool) public registeredArbitrators;
    mapping(address => euint8) public arbitratorReputation;
    uint256 public caseCount;

    event CaseFiled(uint256 indexed caseId, string patentId);
    event VoteCast(uint256 indexed caseId, address indexed arbitrator);
    event CaseResolved(uint256 indexed caseId, bool claimantWon);

    constructor() Ownable(msg.sender) {}

    function registerArbitrator(address arbitrator) external onlyOwner {
        registeredArbitrators[arbitrator] = true;
        arbitratorReputation[arbitrator] = FHE.asEuint8(50);
        FHE.allowThis(arbitratorReputation[arbitrator]);
        FHE.allow(arbitratorReputation[arbitrator], arbitrator);
    }

    function fileCase(
        string calldata patentId,
        address respondent,
        uint256 votingWindow
    ) external returns (uint256 caseId) {
        caseId = caseCount++;
        DisputeCase storage c = cases[caseId];
        c.patentId = patentId;
        c.claimant = msg.sender;
        c.respondent = respondent;
        c.arbitratorVotesForClaimant = FHE.asEuint8(0);
        c.arbitratorVotesForRespondent = FHE.asEuint8(0);
        c.totalArbitrators = FHE.asEuint8(0);
        c.votingDeadline = block.timestamp + votingWindow;
        FHE.allowThis(c.arbitratorVotesForClaimant);
        FHE.allowThis(c.arbitratorVotesForRespondent);
        FHE.allowThis(c.totalArbitrators);
        emit CaseFiled(caseId, patentId);
    }

    function castArbitratorVote(
        uint256 caseId,
        externalEbool calldata encSupportsClaimant,
        bytes calldata inputProof
    ) external {
        require(registeredArbitrators[msg.sender], "Not arbitrator");
        DisputeCase storage c = cases[caseId];
        require(!c.hasVoted[msg.sender], "Already voted");
        require(block.timestamp <= c.votingDeadline, "Voting closed");
        require(!c.resolved, "Resolved");

        ebool supportsClaimant = FHE.fromExternal(encSupportsClaimant, inputProof);
        c.arbitratorVotesForClaimant = FHE.add(
            c.arbitratorVotesForClaimant,
            FHE.select(supportsClaimant, FHE.asEuint8(1), FHE.asEuint8(0))
        );
        c.arbitratorVotesForRespondent = FHE.add(
            c.arbitratorVotesForRespondent,
            FHE.select(FHE.not(supportsClaimant), FHE.asEuint8(1), FHE.asEuint8(0))
        );
        c.totalArbitrators = FHE.add(c.totalArbitrators, FHE.asEuint8(1));
        FHE.allowThis(c.arbitratorVotesForClaimant);
        FHE.allowThis(c.arbitratorVotesForRespondent);
        FHE.allowThis(c.totalArbitrators);
        c.hasVoted[msg.sender] = true;
        emit VoteCast(caseId, msg.sender);
    }

    function resolveCase(uint256 caseId) external onlyOwner {
        DisputeCase storage c = cases[caseId];
        require(block.timestamp > c.votingDeadline, "Voting active");
        require(!c.resolved, "Already resolved");
        ebool claimantWins = FHE.gt(c.arbitratorVotesForClaimant, c.arbitratorVotesForRespondent);
        c.claimantWon = claimantWins.unwrap() != 0;
        c.resolved = true;
        FHE.allow(c.arbitratorVotesForClaimant, owner());
        FHE.allow(c.arbitratorVotesForRespondent, owner());
        emit CaseResolved(caseId, c.claimantWon);
    }
}
