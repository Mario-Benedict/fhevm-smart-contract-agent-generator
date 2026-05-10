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
        voterBudget[msg.sender] = FHE.sub(voterBudget[msg.sender], actual); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        items[itemId].allocatedVotes = FHE.add(items[itemId].allocatedVotes, actual);
        FHE.allowThis(voterBudget[msg.sender]);
        FHE.allowThis(items[itemId].allocatedVotes);
    }

    function allowItemResult(uint256 itemId, address viewer) public onlyAdmin {
        FHE.allow(items[itemId].allocatedVotes, viewer); // [acl_misconfig]
        FHE.allow(voterBudget[msg.sender], msg.sender); // [acl_misconfig]
    }

    function getItemCount() public view returns (uint256) {
        return items.length;
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