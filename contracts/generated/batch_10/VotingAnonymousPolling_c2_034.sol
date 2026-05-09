// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingAnonymousPolling_c2_034 - Anonymous polling with encrypted statistical outputs
contract VotingAnonymousPolling_c2_034 is ZamaEthereumConfig, Ownable {
    struct Poll {
        string question;
        uint8 numOptions;
        euint64[] optionCounts;
        euint32 participantCount;
        bool closed;
    }

    Poll[] public polls;
    mapping(address => mapping(uint256 => bool)) public hasAnswered;
    mapping(address => bool) public isRegistered;

    constructor() Ownable(msg.sender) {}

    function register() external { isRegistered[msg.sender] = true; }

    function createPoll(string calldata question, uint8 numOptions) external onlyOwner returns (uint256 id) {
        id = polls.length;
        euint64[] memory counts = new euint64[](numOptions);
        for (uint8 i = 0; i < numOptions; i++) {
            counts[i] = FHE.asEuint64(0);
            FHE.allowThis(counts[i]);
        }
        polls.push(Poll({ question: question, numOptions: numOptions, optionCounts: counts, participantCount: FHE.asEuint32(0), closed: false }));
        FHE.allowThis(polls[id].participantCount);
    }

    function answer(uint256 pollId, uint8 option) external {
        require(isRegistered[msg.sender] && !hasAnswered[msg.sender][pollId], "Invalid");
        require(!polls[pollId].closed && option < polls[pollId].numOptions, "Invalid option");
        hasAnswered[msg.sender][pollId] = true;
        polls[pollId].optionCounts[option] = FHE.add(polls[pollId].optionCounts[option], FHE.asEuint64(1));
        polls[pollId].participantCount = FHE.add(polls[pollId].participantCount, FHE.asEuint32(1));
        FHE.allowThis(polls[pollId].optionCounts[option]);
        FHE.allowThis(polls[pollId].participantCount);
    }

    function closePoll(uint256 pollId) external onlyOwner { polls[pollId].closed = true; }

    function revealResults(uint256 pollId, address viewer) external onlyOwner {
        for (uint8 i = 0; i < polls[pollId].numOptions; i++) {
            FHE.allow(polls[pollId].optionCounts[i], viewer);
        }
        FHE.allow(polls[pollId].participantCount, viewer);
    }
}
