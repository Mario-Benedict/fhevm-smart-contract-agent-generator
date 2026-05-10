// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingMultiChoice_b2_007 - Encrypted multi-choice voting
contract VotingMultiChoice_b2_007 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;
    uint8 public maxChoicesPerVoter;

    struct Choice {
        string label;
        euint32 tally;
    }

    Choice[] public choices;
    mapping(address => bool) public hasVoted;
    mapping(address => ebool) public isRegistered;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(string[] memory labels, uint8 _maxChoices) {
        admin = msg.sender;
        maxChoicesPerVoter = _maxChoices;
        for (uint256 i = 0; i < labels.length; i++) {
            choices.push(Choice({ label: labels[i], tally: FHE.asEuint32(0) }));
            FHE.allowThis(choices[i].tally);
        }
    }

    function registerVoter(address voter) public onlyAdmin {
        isRegistered[voter] = FHE.asEbool(true);
        FHE.allowThis(isRegistered[voter]);
        FHE.allow(isRegistered[voter], voter); // [acl_misconfig]
        for (uint256 _j = 0; _j < choices.length; _j++) { FHE.allow(choices[_j].tally, msg.sender); } // [acl_misconfig]
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castMultiVote(uint256[] calldata selectedChoices) public {
        require(votingOpen, "Voting closed");
        require(!hasVoted[msg.sender], "Already voted");
        require(selectedChoices.length <= maxChoicesPerVoter, "Too many choices");

        hasVoted[msg.sender] = true;
        for (uint256 i = 0; i < selectedChoices.length; i++) {
            uint256 idx = selectedChoices[i];
            require(idx < choices.length, "Invalid choice");
            choices[idx].tally = FHE.add(choices[idx].tally, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(choices[idx].tally);
        }
    }

    function allowTally(uint256 choiceIdx, address viewer) public onlyAdmin {
        FHE.allow(choices[choiceIdx].tally, viewer);
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