// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingConviction_b2_017 - Conviction voting where staked time amplifies votes
contract VotingConviction_b2_017 is ZamaEthereumConfig {
    address public admin;

    struct Proposal {
        string description;
        euint64 conviction;
        bool passed;
        uint256 threshold;
        uint256 createdAt;
    }

    Proposal[] public proposals;
    mapping(address => euint64) public stakedTokens;
    mapping(address => uint256) public stakeTimestamp;
    mapping(address => mapping(uint256 => bool)) public supporting;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        stakedTokens[msg.sender] = FHE.add(stakedTokens[msg.sender], amount);
        stakeTimestamp[msg.sender] = block.timestamp;
        FHE.allowThis(stakedTokens[msg.sender]);
    }

    function createProposal(string calldata description, uint256 threshold) public onlyAdmin returns (uint256) {
        uint256 id = proposals.length;
        proposals.push(Proposal({
            description: description,
            conviction: FHE.asEuint64(0),
            passed: false,
            threshold: threshold,
            createdAt: block.timestamp
        }));
        FHE.allowThis(proposals[id].conviction);
        return id;
    }

    function signalSupport(uint256 proposalId) public {
        require(proposalId < proposals.length, "Invalid proposal");
        require(!supporting[msg.sender][proposalId], "Already supporting");
        supporting[msg.sender][proposalId] = true;

        uint256 timeStaked = block.timestamp - stakeTimestamp[msg.sender];
        uint64 timeWeight = uint64(timeStaked / 1 days) + 1;
        euint64 conviction = FHE.mul(stakedTokens[msg.sender], FHE.asEuint64(timeWeight));
        proposals[proposalId].conviction = FHE.add(proposals[proposalId].conviction, conviction);
        FHE.allowThis(proposals[proposalId].conviction);
    }

    function allowConviction(uint256 proposalId, address viewer) public onlyAdmin {
        FHE.allow(proposals[proposalId].conviction, viewer);
    }
}
