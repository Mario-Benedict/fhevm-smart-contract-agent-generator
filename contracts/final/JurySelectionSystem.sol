// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title JurySelectionSystem
/// @notice Randomized jury selection with encrypted candidate scoring.
///         Attorneys challenge candidates with sealed reasons; judge rules privately.
contract JurySelectionSystem is ZamaEthereumConfig, Ownable {
    struct JuryCandidate {
        address addr;
        euint8 impartialityScore;  // 1-100 encrypted
        euint8 expertiseScore;
        bool challenged;
        bool selected;
        bool evaluated;
    }

    struct Case {
        string caseId;
        uint8 requiredJurors;
        uint8 selectedCount;
        address[] jurors;
        bool complete;
    }

    mapping(uint256 => Case) public cases;
    mapping(uint256 => JuryCandidate[]) private candidates;
    mapping(address => bool) public isJudge;
    mapping(address => bool) public isAttorney;
    uint256 public caseCount;
    euint8 private _selectionThreshold;

    event CaseOpened(uint256 indexed caseId);
    event CandidateAdded(uint256 indexed caseId, address candidate);
    event JurySeated(uint256 indexed caseId);

    constructor(externalEuint8 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _selectionThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_selectionThreshold);
        isJudge[msg.sender] = true;
    }

    function addJudge(address j) external onlyOwner { isJudge[j] = true; }
    function addAttorney(address a) external onlyOwner { isAttorney[a] = true; }

    function openCase(string calldata caseId, uint8 requiredJurors) external returns (uint256 id) {
        require(isJudge[msg.sender], "Not judge");
        id = caseCount++;
        cases[id] = Case({ caseId: caseId, requiredJurors: requiredJurors, selectedCount: 0, jurors: new address[](0), complete: false });
        emit CaseOpened(id);
    }

    function addCandidate(
        uint256 caseId,
        address candidate,
        externalEuint8 encImpartial, bytes calldata iProof,
        externalEuint8 encExpertise, bytes calldata eProof
    ) external {
        require(isJudge[msg.sender], "Not judge");
        uint256 idx = candidates[caseId].length;
        euint8 impartial = FHE.fromExternal(encImpartial, iProof);
        euint8 expertise = FHE.fromExternal(encExpertise, eProof);
        candidates[caseId].push(JuryCandidate({
            addr: candidate, impartialityScore: impartial, expertiseScore: expertise,
            challenged: false, selected: false, evaluated: false
        }));
        FHE.allowThis(candidates[caseId][idx].impartialityScore);
        FHE.allowThis(candidates[caseId][idx].expertiseScore);
        emit CandidateAdded(caseId, candidate);
    }

    function challengeCandidate(uint256 caseId, uint256 candidateIdx) external {
        require(isAttorney[msg.sender], "Not attorney");
        candidates[caseId][candidateIdx].challenged = true;
    }

    function evaluateAndSelect(uint256 caseId, uint256 candidateIdx) external {
        require(isJudge[msg.sender], "Not judge");
        JuryCandidate storage c = candidates[caseId][candidateIdx];
        require(!c.evaluated && !c.challenged, "Invalid");
        c.evaluated = true;
        euint8 avg = FHE.div(FHE.add(c.impartialityScore, c.expertiseScore), 2); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        ebool qualifies = FHE.ge(avg, _selectionThreshold);
        c.selected = FHE.isInitialized(qualifies);
        if (c.selected) {
            cases[caseId].jurors.push(c.addr);
            cases[caseId].selectedCount++;
            if (cases[caseId].selectedCount >= cases[caseId].requiredJurors) {
                cases[caseId].complete = true;
                emit JurySeated(caseId);
            }
        }
        FHE.allow(avg, owner());
    }

    function allowCandidateScores(uint256 caseId, uint256 candidateIdx, address viewer) external {
        require(isJudge[msg.sender], "Not judge");
        FHE.allow(candidates[caseId][candidateIdx].impartialityScore, viewer);
        FHE.allow(candidates[caseId][candidateIdx].expertiseScore, viewer);
    }
}
