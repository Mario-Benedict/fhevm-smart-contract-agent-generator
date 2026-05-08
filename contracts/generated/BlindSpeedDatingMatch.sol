// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BlindSpeedDatingMatch - Encrypted mutual-interest matching for anonymous speed dating rounds
contract BlindSpeedDatingMatch is ZamaEthereumConfig, Ownable {
    struct Round {
        uint256 startTime;
        uint256 endTime;
        uint8 participantCount;
        bool finalized;
    }

    struct Preference {
        euint8 interestScore;    // 0-100 interest in the other participant
        bool submitted;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => address[]) public roundParticipants;
    mapping(uint256 => mapping(address => mapping(address => Preference))) private prefs;
    mapping(uint256 => mapping(address => bool)) public enrolled;
    mapping(uint256 => mapping(address => mapping(address => bool))) public matched;
    uint256 public roundCount;

    event RoundCreated(uint256 indexed roundId);
    event ParticipantEnrolled(uint256 indexed roundId, address indexed participant);
    event PreferenceSubmitted(uint256 indexed roundId, address indexed from, address indexed to);
    event MatchRevealed(uint256 indexed roundId, address indexed a, address indexed b);

    constructor() Ownable(msg.sender) {}

    function createRound(uint256 duration) external onlyOwner returns (uint256 roundId) {
        roundId = roundCount++;
        rounds[roundId] = Round(block.timestamp, block.timestamp + duration, 0, false);
        emit RoundCreated(roundId);
    }

    function enroll(uint256 roundId) external {
        Round storage r = rounds[roundId];
        require(block.timestamp <= r.endTime, "Closed");
        require(!enrolled[roundId][msg.sender], "Already enrolled");
        enrolled[roundId][msg.sender] = true;
        roundParticipants[roundId].push(msg.sender);
        r.participantCount++;
        emit ParticipantEnrolled(roundId, msg.sender);
    }

    function submitPreference(
        uint256 roundId,
        address target,
        externalEuint8 calldata encScore,
        bytes calldata inputProof
    ) external {
        require(enrolled[roundId][msg.sender], "Not enrolled");
        require(enrolled[roundId][target], "Target not enrolled");
        require(msg.sender != target, "Cannot self-score");
        Preference storage p = prefs[roundId][msg.sender][target];
        require(!p.submitted, "Already submitted");
        p.interestScore = FHE.fromExternal(encScore, inputProof);
        p.submitted = true;
        FHE.allowThis(p.interestScore);
        emit PreferenceSubmitted(roundId, msg.sender, target);
    }

    function finalizeRound(uint256 roundId) external onlyOwner {
        Round storage r = rounds[roundId];
        require(block.timestamp > r.endTime, "Not ended");
        require(!r.finalized, "Done");
        address[] storage pts = roundParticipants[roundId];
        for (uint i = 0; i < pts.length; i++) {
            for (uint j = i + 1; j < pts.length; j++) {
                address a = pts[i]; address b = pts[j];
                if (prefs[roundId][a][b].submitted && prefs[roundId][b][a].submitted) {
                    euint8 scoreAB = prefs[roundId][a][b].interestScore;
                    euint8 scoreBA = prefs[roundId][b][a].interestScore;
                    ebool mutualInterest = FHE.and(
                        FHE.ge(scoreAB, FHE.asEuint8(50)),
                        FHE.ge(scoreBA, FHE.asEuint8(50))
                    );
                    if (mutualInterest.unwrap() != 0) {
                        matched[roundId][a][b] = true;
                        matched[roundId][b][a] = true;
                        FHE.allow(scoreAB, b);
                        FHE.allow(scoreBA, a);
                        emit MatchRevealed(roundId, a, b);
                    }
                }
            }
        }
        r.finalized = true;
    }

    function isMatch(uint256 roundId, address other) external view returns (bool) {
        return matched[roundId][msg.sender][other];
    }
}
