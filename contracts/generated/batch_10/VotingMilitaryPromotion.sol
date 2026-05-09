// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingMilitaryPromotion
/// @notice Officer promotion board where performance ratings are encrypted.
///         A board of generals votes with encrypted numerical assessments per officer.
contract VotingMilitaryPromotion is ZamaEthereumConfig, Ownable {
    struct Officer {
        string name;
        string rank;
        euint16 combatScore;
        euint16 leadershipScore;
        euint16 strategicScore;
        uint8 boardMembersScored;
        bool promoted;
        bool finalized;
    }

    mapping(uint256 => Officer) private officers;
    uint256 public officerCount;
    mapping(address => bool) public isBoardMember;
    mapping(uint256 => mapping(address => bool)) private hasScored;
    euint16 private _promotionThreshold;

    event OfficerNominated(uint256 indexed id, string name);
    event BoardScoreSubmitted(uint256 indexed id, address member);
    event PromotionDecision(uint256 indexed id, bool promoted);

    constructor(externalEuint16 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _promotionThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_promotionThreshold);
        isBoardMember[msg.sender] = true;
    }

    function addBoardMember(address m) external onlyOwner { isBoardMember[m] = true; }

    function nominateOfficer(string calldata name, string calldata rank) external onlyOwner returns (uint256 id) {
        id = officerCount++;
        officers[id].name = name;
        officers[id].rank = rank;
        officers[id].combatScore = FHE.asEuint16(0);
        officers[id].leadershipScore = FHE.asEuint16(0);
        officers[id].strategicScore = FHE.asEuint16(0);
        FHE.allowThis(officers[id].combatScore);
        FHE.allowThis(officers[id].leadershipScore);
        FHE.allowThis(officers[id].strategicScore);
        emit OfficerNominated(id, name);
    }

    function submitBoardScore(
        uint256 id,
        externalEuint16 encCombat, bytes calldata cProof,
        externalEuint16 encLeadership, bytes calldata lProof,
        externalEuint16 encStrategic, bytes calldata sProof
    ) external {
        require(isBoardMember[msg.sender], "Not board member");
        require(id < officerCount, "Invalid id");
        require(!hasScored[id][msg.sender], "Already scored");
        hasScored[id][msg.sender] = true;
        Officer storage o = officers[id];
        o.combatScore = FHE.add(o.combatScore, FHE.fromExternal(encCombat, cProof));
        o.leadershipScore = FHE.add(o.leadershipScore, FHE.fromExternal(encLeadership, lProof));
        o.strategicScore = FHE.add(o.strategicScore, FHE.fromExternal(encStrategic, sProof));
        o.boardMembersScored++;
        FHE.allowThis(o.combatScore);
        FHE.allowThis(o.leadershipScore);
        FHE.allowThis(o.strategicScore);
        emit BoardScoreSubmitted(id, msg.sender);
    }

    function finalizePromotion(uint256 id) external onlyOwner {
        Officer storage o = officers[id];
        require(!o.finalized && o.boardMembersScored >= 3, "Cannot finalize");
        o.finalized = true;
        uint16 count = uint16(o.boardMembersScored);
        euint16 avgCombat = FHE.div(o.combatScore, count);
        euint16 avgLeader = FHE.div(o.leadershipScore, count);
        euint16 avgStrategic = FHE.div(o.strategicScore, count);
        euint16 totalAvg = FHE.div(FHE.add(FHE.add(avgCombat, avgLeader), avgStrategic), 3);
        ebool promoted = FHE.ge(totalAvg, _promotionThreshold);
        o.promoted = FHE.isInitialized(promoted);
        emit PromotionDecision(id, o.promoted);
    }

    function allowOfficerScores(uint256 id, address viewer) external onlyOwner {
        FHE.allow(officers[id].combatScore, viewer);
        FHE.allow(officers[id].leadershipScore, viewer);
        FHE.allow(officers[id].strategicScore, viewer);
    }
}
