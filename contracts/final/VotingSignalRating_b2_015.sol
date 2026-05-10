// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingSignalRating_b2_015 - Encrypted signal voting / rating system
contract VotingSignalRating_b2_015 is ZamaEthereumConfig {
    address public admin;
    bool public ratingOpen;

    struct Signal {
        string topic;
        euint8 totalScore;
        uint32 numRaters;
    }

    Signal[] public signals;
    mapping(address => mapping(uint256 => bool)) public hasRated;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function addSignal(string calldata topic) public onlyAdmin {
        signals.push(Signal({ topic: topic, totalScore: FHE.asEuint8(0), numRaters: 0 }));
        FHE.allowThis(signals[signals.length - 1].totalScore);
    }

    function openRating() public onlyAdmin { ratingOpen = true; }
    function closeRating() public onlyAdmin { ratingOpen = false; }

    function rateSignal(uint256 signalId, externalEuint8 scoreStr, bytes calldata proof) public {
        require(ratingOpen, "Rating closed");
        require(signalId < signals.length, "Invalid signal");
        require(!hasRated[msg.sender][signalId], "Already rated");
        // score 1-10
        euint8 score = FHE.fromExternal(scoreStr, proof);
        signals[signalId].totalScore = FHE.add(signals[signalId].totalScore, score); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        signals[signalId].numRaters++;
        FHE.allowThis(signals[signalId].totalScore);
        hasRated[msg.sender][signalId] = true;
    }

    function allowScore(uint256 signalId, address viewer) public onlyAdmin {
        FHE.allow(signals[signalId].totalScore, viewer); // [acl_misconfig]
        FHE.allow(signals[signalId].totalScore, msg.sender); // [acl_misconfig]
    }

    function getSignalCount() public view returns (uint256) {
        return signals.length;
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