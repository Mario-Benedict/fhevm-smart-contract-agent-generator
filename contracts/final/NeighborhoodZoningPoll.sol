// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title NeighborhoodZoningPoll - Private ranked-choice zoning preference vote
contract NeighborhoodZoningPoll is ZamaEthereumConfig, Ownable {
    uint8 public constant NUM_OPTIONS = 4; // Residential, Commercial, Mixed, Green

    struct Poll {
        string description;
        euint16[4] tallies;
        uint256 deadline;
        bool closed;
    }

    mapping(uint256 => Poll) public polls;
    mapping(uint256 => mapping(address => bool)) public participated;
    mapping(address => bool) public eligibleResidents;
    uint256 public pollCount;

    event PollOpened(uint256 indexed pollId);
    event PreferenceSubmitted(uint256 indexed pollId, address indexed resident);
    event PollClosed(uint256 indexed pollId);

    constructor() Ownable(msg.sender) {}

    function approveResident(address resident) external onlyOwner {
        eligibleResidents[resident] = true;
    }

    function openPoll(string calldata description, uint256 duration) external onlyOwner returns (uint256 pollId) {
        pollId = pollCount++;
        Poll storage p = polls[pollId];
        p.description = description;
        p.deadline = block.timestamp + duration;
        for (uint8 i = 0; i < NUM_OPTIONS; i++) {
            p.tallies[i] = FHE.asEuint16(0);
            FHE.allowThis(p.tallies[i]);
        }
        emit PollOpened(pollId);
    }

    function submitPreference(
        uint256 pollId,
        externalEuint16[4] calldata encRanks,
        bytes[4] calldata inputProofs
    ) external {
        require(eligibleResidents[msg.sender], "Not eligible");
        require(!participated[pollId][msg.sender], "Already voted");
        Poll storage p = polls[pollId];
        require(block.timestamp <= p.deadline && !p.closed, "Poll closed");

        for (uint8 i = 0; i < NUM_OPTIONS; i++) {
            euint16 rank = FHE.fromExternal(encRanks[i], inputProofs[i]);
            p.tallies[i] = FHE.add(p.tallies[i], rank);
            FHE.allowThis(p.tallies[i]);
        }
        participated[pollId][msg.sender] = true;
        emit PreferenceSubmitted(pollId, msg.sender);
    }

    function closePoll(uint256 pollId) external onlyOwner {
        Poll storage p = polls[pollId];
        require(!p.closed, "Already closed");
        p.closed = true;
        for (uint8 i = 0; i < NUM_OPTIONS; i++) {
            FHE.allow(p.tallies[i], owner());
        }
        emit PollClosed(pollId);
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