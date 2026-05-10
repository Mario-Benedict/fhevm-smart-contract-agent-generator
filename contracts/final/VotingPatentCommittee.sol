// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingPatentCommittee
/// @notice Patent approval committee where technical merit scores are encrypted.
///         Examiners score novelty, inventiveness, and industrial applicability privately.
contract VotingPatentCommittee is ZamaEthereumConfig, Ownable {
    struct PatentApplication {
        string title;
        address applicant;
        euint8 noveltyScore;
        euint8 inventivenessScore;
        euint8 applicabilityScore;
        uint8 examinerCount;
        bool approved;
        bool finalized;
    }

    mapping(uint256 => PatentApplication) private applications;
    uint256 public applicationCount;
    mapping(address => bool) public isExaminer;
    mapping(uint256 => mapping(address => bool)) private hasExamined;
    euint8 private _approvalThreshold;

    event ApplicationSubmitted(uint256 indexed id, address applicant);
    event ExaminationDone(uint256 indexed id, address examiner);
    event PatentDecision(uint256 indexed id, bool approved);

    constructor(externalEuint8 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _approvalThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_approvalThreshold);
        isExaminer[msg.sender] = true;
    }

    function addExaminer(address e) external onlyOwner { isExaminer[e] = true; }

    function submitApplication(string calldata title) external returns (uint256 id) {
        id = applicationCount++;
        PatentApplication storage app = applications[id];
        app.title = title;
        app.applicant = msg.sender;
        app.noveltyScore = FHE.asEuint8(0);
        app.inventivenessScore = FHE.asEuint8(0);
        app.applicabilityScore = FHE.asEuint8(0);
        app.examinerCount = 0;
        FHE.allowThis(app.noveltyScore);
        FHE.allowThis(app.inventivenessScore);
        FHE.allowThis(app.applicabilityScore);
        emit ApplicationSubmitted(id, msg.sender);
    }

    function examine(
        uint256 id,
        externalEuint8 encNovelty, bytes calldata nProof,
        externalEuint8 encInventiveness, bytes calldata iProof,
        externalEuint8 encApplicability, bytes calldata aProof
    ) external {
        require(isExaminer[msg.sender], "Not examiner");
        require(id < applicationCount, "Invalid id");
        require(!hasExamined[id][msg.sender], "Already examined");
        hasExamined[id][msg.sender] = true;

        PatentApplication storage app = applications[id];
        euint8 n = FHE.fromExternal(encNovelty, nProof);
        euint8 inv = FHE.fromExternal(encInventiveness, iProof);
        euint8 appl = FHE.fromExternal(encApplicability, aProof);

        app.noveltyScore = FHE.add(app.noveltyScore, n); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        app.inventivenessScore = FHE.add(app.inventivenessScore, inv);
        app.applicabilityScore = FHE.add(app.applicabilityScore, appl);
        app.examinerCount++;

        FHE.allowThis(app.noveltyScore);
        FHE.allowThis(app.inventivenessScore);
        FHE.allowThis(app.applicabilityScore);
        emit ExaminationDone(id, msg.sender);
    }

    function finalizeDecision(uint256 id) external onlyOwner {
        PatentApplication storage app = applications[id];
        require(!app.finalized, "Already finalized");
        require(app.examinerCount >= 3, "Need 3 examiners");
        euint8 count = FHE.asEuint8(app.examinerCount);
        euint8 avgNovelty = FHE.div(app.noveltyScore, app.examinerCount);
        euint8 avgInv = FHE.div(app.inventivenessScore, app.examinerCount);
        euint8 avgAppl = FHE.div(app.applicabilityScore, app.examinerCount);
        ebool nOk = FHE.ge(avgNovelty, _approvalThreshold);
        ebool iOk = FHE.ge(avgInv, _approvalThreshold);
        ebool aOk = FHE.ge(avgAppl, _approvalThreshold);
        ebool allPassed = FHE.and(FHE.and(nOk, iOk), aOk);
        app.approved = FHE.isInitialized(allPassed);
        app.finalized = true;
        FHE.allow(app.noveltyScore, app.applicant); // [acl_misconfig]
        FHE.allow(_approvalThreshold, msg.sender); // [acl_misconfig]
        FHE.allow(app.inventivenessScore, app.applicant);
        FHE.allow(app.applicabilityScore, app.applicant);
        emit PatentDecision(id, app.approved);
    }

    function isApproved(uint256 id) external view returns (bool) {
        return applications[id].approved && applications[id].finalized;
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