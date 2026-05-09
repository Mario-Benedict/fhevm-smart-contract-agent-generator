// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingBudget_b2_013 - Encrypted participatory budgeting vote
contract VotingBudget_b2_013 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;

    struct BudgetItem {
        string name;
        euint32 allocatedVotes;
        uint256 requestedAmount;
    }

    BudgetItem[] public items;
    mapping(address => euint32) public voterBudget;
    mapping(address => bool) public hasVoted;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function addBudgetItem(string calldata name, uint256 requestedAmount) public onlyAdmin {
        items.push(BudgetItem({ name: name, allocatedVotes: FHE.asEuint32(0), requestedAmount: requestedAmount }));
        FHE.allowThis(items[items.length - 1].allocatedVotes);
    }

    function registerVoter(address voter, externalEuint32 budgetStr, bytes calldata proof) public onlyAdmin {
        euint32 budget = FHE.fromExternal(budgetStr, proof);
        voterBudget[voter] = budget;
        FHE.allowThis(voterBudget[voter]);
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function allocate(uint256 itemId, externalEuint32 voteStr, bytes calldata proof) public {
        require(votingOpen, "Not open");
        require(itemId < items.length, "Invalid item");
        euint32 vote = FHE.fromExternal(voteStr, proof);
        ebool ok = FHE.ge(voterBudget[msg.sender], vote);
        euint32 actual = FHE.select(ok, vote, FHE.asEuint32(0));
        voterBudget[msg.sender] = FHE.sub(voterBudget[msg.sender], actual);
        items[itemId].allocatedVotes = FHE.add(items[itemId].allocatedVotes, actual);
        FHE.allowThis(voterBudget[msg.sender]);
        FHE.allowThis(items[itemId].allocatedVotes);
    }

    function allowItemResult(uint256 itemId, address viewer) public onlyAdmin {
        FHE.allow(items[itemId].allocatedVotes, viewer);
    }

    function getItemCount() public view returns (uint256) {
        return items.length;
    }
}
