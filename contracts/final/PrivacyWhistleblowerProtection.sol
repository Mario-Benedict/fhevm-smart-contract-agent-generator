// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivacyWhistleblowerProtection
/// @notice Encrypted whistleblower submission system. Reports are stored encrypted;
///         only designated investigators can decrypt specific reports with explicit
///         case authorization.
contract PrivacyWhistleblowerProtection is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ReportStatus { Submitted, UnderReview, ActionTaken, Dismissed }

    struct Report {
        euint64 reportHash;     // encrypted hash of report content
        euint8 severityScore;   // encrypted 1-5
        euint8 categoryCode;    // encrypted: 1=fraud, 2=safety, 3=environmental, etc.
        ReportStatus status;
        uint256 submittedAt;
        bool assigned;
        address assignedTo;
    }

    mapping(uint256 => Report) private reports;
    uint256 public reportCount;
    mapping(address => bool) public isInvestigator;
    mapping(uint256 => address[]) private authorizedInvestigators;
    euint64 private _rewardPool;
    euint64 private _rewardPerValidReport;

    event ReportSubmitted(uint256 indexed id);
    event ReportAssigned(uint256 indexed id, address investigator);
    event ReportResolved(uint256 indexed id, ReportStatus status);

    constructor(
        externalEuint64 encRewardPerReport, bytes memory proof
    ) Ownable(msg.sender) {
        _rewardPerValidReport = FHE.fromExternal(encRewardPerReport, proof);
        _rewardPool = FHE.asEuint64(0);
        FHE.allowThis(_rewardPerValidReport);
        FHE.allowThis(_rewardPool);
    }

    function fundRewardPool(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _rewardPool = FHE.add(_rewardPool, amount);
        FHE.allowThis(_rewardPool);
    }

    function addInvestigator(address inv) external onlyOwner { isInvestigator[inv] = true; }

    function submitReport(
        externalEuint64 encReportHash, bytes calldata hProof,
        externalEuint8 encSeverity, bytes calldata sProof,
        externalEuint8 encCategory, bytes calldata cProof
    ) external nonReentrant returns (uint256 id) {
        id = reportCount++;
        reports[id].reportHash = FHE.fromExternal(encReportHash, hProof);
        reports[id].severityScore = FHE.fromExternal(encSeverity, sProof);
        reports[id].categoryCode = FHE.fromExternal(encCategory, cProof);
        reports[id].status = ReportStatus.Submitted;
        reports[id].submittedAt = block.timestamp;
        FHE.allowThis(reports[id].reportHash);
        FHE.allow(reports[id].reportHash, msg.sender);  // only submitter sees hash initially
        FHE.allowThis(reports[id].severityScore);
        FHE.allowThis(reports[id].categoryCode);
        emit ReportSubmitted(id);
    }

    function assignInvestigator(uint256 reportId, address investigator) external onlyOwner {
        require(isInvestigator[investigator], "Not investigator");
        require(!reports[reportId].assigned, "Already assigned");
        reports[reportId].assigned = true;
        reports[reportId].assignedTo = investigator;
        reports[reportId].status = ReportStatus.UnderReview;
        authorizedInvestigators[reportId].push(investigator);
        FHE.allow(reports[reportId].reportHash, investigator);
        FHE.allow(reports[reportId].severityScore, investigator);
        FHE.allow(reports[reportId].categoryCode, investigator);
        emit ReportAssigned(reportId, investigator);
    }

    function resolveReport(
        uint256 reportId, ReportStatus resolution, address whistleblower
    ) external {
        require(isInvestigator[msg.sender] && reports[reportId].assignedTo == msg.sender, "No access");
        reports[reportId].status = resolution;
        if (resolution == ReportStatus.ActionTaken && whistleblower != address(0)) {
            ebool hasFunds = FHE.ge(_rewardPool, _rewardPerValidReport);
            euint64 reward = FHE.select(hasFunds, _rewardPerValidReport, _rewardPool);
            _rewardPool = FHE.sub(_rewardPool, reward);
            FHE.allow(reward, whistleblower);
            FHE.allowThis(_rewardPool);
        }
        emit ReportResolved(reportId, resolution);
    }

    function allowReportToRegulator(uint256 reportId, address regulator) external onlyOwner {
        FHE.allow(reports[reportId].reportHash, regulator);
        FHE.allow(reports[reportId].severityScore, regulator);
        FHE.allow(reports[reportId].categoryCode, regulator);
    }

    function getReportStatus(uint256 reportId) external view returns (ReportStatus) {
        return reports[reportId].status;
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