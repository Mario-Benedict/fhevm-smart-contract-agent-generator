// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingTokenWeighted_b2_010 - Encrypted token-weighted voting with snapshot
contract VotingTokenWeighted_b2_010 is ZamaEthereumConfig {
    address public admin;

    struct Poll {
        string question;
        euint64 yesVotes;
        euint64 noVotes;
        euint64 abstainVotes;
        bool closed;
        uint256 snapshotBlock;
    }

    Poll[] public polls;
    mapping(address => euint64) public tokenBalance;
    mapping(address => mapping(uint256 => bool)) public voted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function setBalance(address holder, externalEuint64 balStr, bytes calldata proof) public onlyAdmin {
        euint64 bal = FHE.fromExternal(balStr, proof);
        tokenBalance[holder] = bal;
        FHE.allowThis(tokenBalance[holder]);
    }

    function createPoll(string calldata question) public onlyAdmin returns (uint256) {
        uint256 id = polls.length;
        polls.push(Poll({
            question: question,
            yesVotes: FHE.asEuint64(0),
            noVotes: FHE.asEuint64(0),
            abstainVotes: FHE.asEuint64(0),
            closed: false,
            snapshotBlock: block.number
        }));
        FHE.allowThis(polls[id].yesVotes);
        FHE.allowThis(polls[id].noVotes);
        FHE.allowThis(polls[id].abstainVotes);
        return id;
    }

    function voteOnPoll(uint256 pollId, uint8 choice, externalEuint64 weightStr, bytes calldata proof) public {
        // choice: 0=yes, 1=no, 2=abstain
        require(pollId < polls.length, "Invalid poll");
        Poll storage p = polls[pollId];
        require(!p.closed, "Poll closed");
        require(!voted[msg.sender][pollId], "Already voted");
        require(choice <= 2, "Invalid choice");

        euint64 weight = FHE.fromExternal(weightStr, proof);
        voted[msg.sender][pollId] = true;

        if (choice == 0) {
            p.yesVotes = FHE.add(p.yesVotes, weight);
            FHE.allowThis(p.yesVotes);
        } else if (choice == 1) {
            p.noVotes = FHE.add(p.noVotes, weight);
            FHE.allowThis(p.noVotes);
        } else {
            p.abstainVotes = FHE.add(p.abstainVotes, weight);
            FHE.allowThis(p.abstainVotes);
        }
    }

    function closePoll(uint256 pollId) public onlyAdmin {
        polls[pollId].closed = true;
    }

    function allowResults(uint256 pollId, address viewer) public onlyAdmin {
        FHE.allow(polls[pollId].yesVotes, viewer);
        FHE.allow(polls[pollId].noVotes, viewer);
        FHE.allow(polls[pollId].abstainVotes, viewer);
    }
}
