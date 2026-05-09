// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingCumulative_b2_014 - Encrypted cumulative voting (distribute N votes)
contract VotingCumulative_b2_014 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;
    uint32 public votesPerVoter;

    struct Option {
        string name;
        euint32 totalVotes;
    }

    Option[] public options;
    mapping(address => uint32) public remainingVotes;
    mapping(address => bool) public registered;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint32 _votesPerVoter) {
        admin = msg.sender;
        votesPerVoter = _votesPerVoter;
    }

    function addOption(string calldata name) public onlyAdmin {
        options.push(Option({ name: name, totalVotes: FHE.asEuint32(0) }));
        FHE.allowThis(options[options.length - 1].totalVotes);
    }

    function registerVoter(address voter) public onlyAdmin {
        registered[voter] = true;
        remainingVotes[voter] = votesPerVoter;
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castVotes(uint256 optionId, uint32 numVotes) public {
        require(votingOpen, "Not open");
        require(registered[msg.sender], "Not registered");
        require(optionId < options.length, "Invalid option");
        require(numVotes <= remainingVotes[msg.sender], "Not enough votes");
        remainingVotes[msg.sender] -= numVotes;
        options[optionId].totalVotes = FHE.add(options[optionId].totalVotes, FHE.asEuint32(numVotes));
        FHE.allowThis(options[optionId].totalVotes);
    }

    function allowResult(uint256 optionId, address viewer) public onlyAdmin {
        FHE.allow(options[optionId].totalVotes, viewer);
    }

    function getOptionCount() public view returns (uint256) {
        return options.length;
    }
}
