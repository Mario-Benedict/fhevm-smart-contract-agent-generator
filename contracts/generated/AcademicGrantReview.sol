// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AcademicGrantReview - Blind peer-review scoring for research grant applications
contract AcademicGrantReview is ZamaEthereumConfig, AccessControl {
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    struct Application {
        string applicantId;  // anonymized
        euint8 totalScore;
        uint8 reviewerCount;
        uint8 maxReviewers;
        bool finalized;
        mapping(address => bool) reviewed;
    }

    mapping(uint256 => Application) public applications;
    uint256 public applicationCount;

    event ApplicationSubmitted(uint256 indexed appId);
    event ReviewSubmitted(uint256 indexed appId, address indexed reviewer);
    event ApplicationFinalized(uint256 indexed appId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function submitApplication(string calldata applicantId, uint8 maxReviewers)
        external
        onlyRole(ADMIN_ROLE)
        returns (uint256 appId)
    {
        appId = applicationCount++;
        Application storage a = applications[appId];
        a.applicantId = applicantId;
        a.maxReviewers = maxReviewers;
        a.totalScore = FHE.asEuint8(0);
        FHE.allowThis(a.totalScore);
        emit ApplicationSubmitted(appId);
    }

    function submitReview(uint256 appId, externalEuint8 calldata encScore, bytes calldata inputProof)
        external
        onlyRole(REVIEWER_ROLE)
    {
        Application storage a = applications[appId];
        require(!a.reviewed[msg.sender], "Already reviewed");
        require(a.reviewerCount < a.maxReviewers, "Review quota full");
        require(!a.finalized, "Finalized");

        euint8 score = FHE.fromExternal(encScore, inputProof);
        a.totalScore = FHE.add(a.totalScore, score);
        FHE.allowThis(a.totalScore);
        a.reviewed[msg.sender] = true;
        a.reviewerCount++;
        emit ReviewSubmitted(appId, msg.sender);
    }

    function finalizeApplication(uint256 appId) external onlyRole(ADMIN_ROLE) {
        Application storage a = applications[appId];
        require(!a.finalized, "Already finalized");
        a.finalized = true;
        FHE.allow(a.totalScore, msg.sender);
        emit ApplicationFinalized(appId);
    }
}
