// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract WhistleblowerDAO is ZamaEthereumConfig, AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Proposal {
        euint32 encryptedForVotes;
        euint32 encryptedAgainstVotes;
        uint256 endTime;
        bool resolved;
        bool passed;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(address => ebool) private encryptedBlacklist;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    
    uint256 public proposalCount;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function setBlacklistStatus(
        address account,
        externalEbool memory extStatus,
        bytes calldata inputProof
    ) external onlyRole(ADMIN_ROLE) {
        ebool status = FHE.fromExternal(extStatus, inputProof);
        FHE.allowThis(status);
        encryptedBlacklist[account] = status;
    }

    function createProposal(uint256 votingDuration) external onlyRole(ADMIN_ROLE) {
        uint256 proposalId = proposalCount++;
        
        euint32 initialFor = FHE.asEuint32(0);
        euint32 initialAgainst = FHE.asEuint32(0);
        FHE.allowThis(initialFor);
        FHE.allowThis(initialAgainst);

        proposals[proposalId] = Proposal({
            encryptedForVotes: initialFor,
            encryptedAgainstVotes: initialAgainst,
            endTime: block.timestamp + votingDuration,
            resolved: false,
            passed: false
        });
    }

    function castEncryptedVote(
        uint256 proposalId,
        externalEbool memory isForVote,
        bytes calldata inputProof
    ) external {
        require(block.timestamp < proposals[proposalId].endTime, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        // Check if user is blacklisted silently. If blacklisted, their vote weight becomes 0.
        ebool isBlacklisted = encryptedBlacklist[msg.sender];
        euint32 voteWeight = FHE.select(isBlacklisted, FHE.asEuint32(0), FHE.asEuint32(1));
        FHE.allowThis(voteWeight);

        ebool voteDirection = FHE.fromExternal(isForVote, inputProof);
        FHE.allowThis(voteDirection);

        // Calculate additions
        euint32 addFor = FHE.select(voteDirection, voteWeight, FHE.asEuint32(0));
        euint32 addAgainst = FHE.select(FHE.not(voteDirection), voteWeight, FHE.asEuint32(0));
        
        FHE.allowThis(addFor);
        FHE.allowThis(addAgainst);

        proposals[proposalId].encryptedForVotes = FHE.add(proposals[proposalId].encryptedForVotes, addFor);
        proposals[proposalId].encryptedAgainstVotes = FHE.add(proposals[proposalId].encryptedAgainstVotes, addAgainst);
        
        FHE.allowThis(proposals[proposalId].encryptedForVotes);
        FHE.allowThis(proposals[proposalId].encryptedAgainstVotes);

        hasVoted[proposalId][msg.sender] = true;
    }
}