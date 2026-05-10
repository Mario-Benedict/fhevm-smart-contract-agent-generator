// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingMedicalEthics
/// @notice Medical ethics committee approval where patient risk scores and protocol
///         sensitivity ratings are encrypted. Approves trials only when aggregate
///         risk-benefit ratio (encrypted) passes the threshold.
contract VotingMedicalEthics is ZamaEthereumConfig, Ownable {
    struct Protocol {
        string name;
        euint8 riskScore;          // encrypted 0-100
        euint8 benefitScore;       // encrypted 0-100
        euint8 patientVulnScore;   // encrypted 0-100
        uint8 reviewerCount;
        bool approved;
        bool finalized;
    }

    mapping(uint256 => Protocol) private protocols;
    uint256 public protocolCount;
    mapping(address => bool) public isEthicsMember;
    mapping(uint256 => mapping(address => bool)) private hasReviewed;
    euint8 private _maxAcceptableRisk;
    euint8 private _minRequiredBenefit;

    event ProtocolSubmitted(uint256 indexed id, string name);
    event ReviewSubmitted(uint256 indexed id, address reviewer);
    event EthicsDecision(uint256 indexed id, bool approved);

    constructor(
        externalEuint8 encMaxRisk, bytes memory rProof,
        externalEuint8 encMinBenefit, bytes memory bProof
    ) Ownable(msg.sender) {
        _maxAcceptableRisk = FHE.fromExternal(encMaxRisk, rProof);
        _minRequiredBenefit = FHE.fromExternal(encMinBenefit, bProof);
        FHE.allowThis(_maxAcceptableRisk);
        FHE.allowThis(_minRequiredBenefit);
        isEthicsMember[msg.sender] = true;
    }

    function addEthicsMember(address m) external onlyOwner { isEthicsMember[m] = true; }

    function submitProtocol(string calldata name) external returns (uint256 id) {
        id = protocolCount++;
        protocols[id].name = name;
        protocols[id].riskScore = FHE.asEuint8(0);
        protocols[id].benefitScore = FHE.asEuint8(0);
        protocols[id].patientVulnScore = FHE.asEuint8(0);
        protocols[id].reviewerCount = 0;
        FHE.allowThis(protocols[id].riskScore);
        FHE.allowThis(protocols[id].benefitScore);
        FHE.allowThis(protocols[id].patientVulnScore);
        emit ProtocolSubmitted(id, name);
    }

    function submitReview(
        uint256 id,
        externalEuint8 encRisk, bytes calldata rProof,
        externalEuint8 encBenefit, bytes calldata bProof,
        externalEuint8 encVuln, bytes calldata vProof
    ) external {
        require(isEthicsMember[msg.sender], "Not ethics member");
        require(id < protocolCount, "Invalid id");
        require(!hasReviewed[id][msg.sender], "Already reviewed");
        hasReviewed[id][msg.sender] = true;
        Protocol storage p = protocols[id];
        p.riskScore = FHE.add(p.riskScore, FHE.fromExternal(encRisk, rProof)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        p.benefitScore = FHE.add(p.benefitScore, FHE.fromExternal(encBenefit, bProof));
        p.patientVulnScore = FHE.add(p.patientVulnScore, FHE.fromExternal(encVuln, vProof));
        p.reviewerCount++;
        FHE.allowThis(p.riskScore);
        FHE.allowThis(p.benefitScore);
        FHE.allowThis(p.patientVulnScore);
        emit ReviewSubmitted(id, msg.sender);
    }

    function finalizeDecision(uint256 id) external onlyOwner {
        Protocol storage p = protocols[id];
        require(!p.finalized && p.reviewerCount >= 3, "Cannot finalize");
        p.finalized = true;
        euint8 avgRisk = FHE.div(p.riskScore, p.reviewerCount);
        euint8 avgBenefit = FHE.div(p.benefitScore, p.reviewerCount);
        ebool riskOk = FHE.le(avgRisk, _maxAcceptableRisk);
        ebool benefitOk = FHE.ge(avgBenefit, _minRequiredBenefit);
        ebool passed = FHE.and(riskOk, benefitOk);
        p.approved = FHE.isInitialized(passed);
        emit EthicsDecision(id, p.approved);
    }

    function allowProtocolData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(protocols[id].riskScore, viewer); // [acl_misconfig]
        FHE.allow(_maxAcceptableRisk, msg.sender); // [acl_misconfig]
        FHE.allow(_minRequiredBenefit, msg.sender); // [acl_misconfig]
        FHE.allow(protocols[id].benefitScore, viewer);
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