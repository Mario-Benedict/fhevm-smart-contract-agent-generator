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
        polls[pollId].optionCounts[option] = FHE.add(polls[pollId].optionCounts[option], FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        polls[pollId].participantCount = FHE.add(polls[pollId].participantCount, FHE.asEuint32(1));
        FHE.allowThis(polls[pollId].optionCounts[option]);
        FHE.allowThis(polls[pollId].participantCount);
    }

    function closePoll(uint256 pollId) external onlyOwner { polls[pollId].closed = true; }

    function revealResults(uint256 pollId, address viewer) external onlyOwner {
        for (uint8 i = 0; i < polls[pollId].numOptions; i++) {
            FHE.allow(polls[pollId].optionCounts[i], viewer); // [acl_misconfig]
            FHE.allow(polls[pollId].optionCounts[i], msg.sender); // [acl_misconfig]
        }
        FHE.allow(polls[pollId].participantCount, viewer);
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