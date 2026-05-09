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
        signals[signalId].totalScore = FHE.add(signals[signalId].totalScore, score);
        signals[signalId].numRaters++;
        FHE.allowThis(signals[signalId].totalScore);
        hasRated[msg.sender][signalId] = true;
    }

    function allowScore(uint256 signalId, address viewer) public onlyAdmin {
        FHE.allow(signals[signalId].totalScore, viewer);
    }

    function getSignalCount() public view returns (uint256) {
        return signals.length;
    }
}
