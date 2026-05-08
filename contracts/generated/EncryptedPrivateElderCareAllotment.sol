// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateElderCareAllotment
/// @notice Elder care home allocation where financial means-testing assessments,
///         subsidy levels, and fee co-payments are encrypted. Social workers
///         can assess need without revealing financial data to care facilities.
contract EncryptedPrivateElderCareAllotment is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant SOCIAL_WORKER_ROLE = keccak256("SOCIAL_WORKER_ROLE");
    bytes32 public constant CARE_HOME_ROLE = keccak256("CARE_HOME_ROLE");
    bytes32 public constant FINANCE_ROLE = keccak256("FINANCE_ROLE");

    enum AllotmentStatus { Pending, Assessed, Approved, Active, Discharged }

    struct CareAllotment {
        address resident;
        address careHome;
        euint64 monthlyFee;         // encrypted total monthly care fee
        euint64 subsidy;            // encrypted government subsidy portion
        euint64 copayment;          // encrypted resident co-payment
        euint64 assetsMeansTest;    // encrypted resident assets for means test
        euint32 needScore;          // encrypted care need score (0-100)
        uint256 assessmentDate;
        uint256 admissionDate;
        AllotmentStatus status;
    }

    uint256 public nextAllotmentId;
    mapping(uint256 => CareAllotment) private allotments;
    mapping(address => uint256) public residentAllotment;

    event AllotmentRequested(uint256 indexed id, address resident, address careHome);
    event MeansTestCompleted(uint256 indexed id);
    event AllotmentApproved(uint256 indexed id);
    event ResidentAdmitted(uint256 indexed id);
    event ResidentDischarged(uint256 indexed id);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(SOCIAL_WORKER_ROLE, msg.sender);
        _grantRole(FINANCE_ROLE, msg.sender);
    }

    function requestAllotment(
        address careHome,
        externalEuint64 encAssets,
        bytes calldata assetsProof
    ) external returns (uint256 id) {
        id = nextAllotmentId++;
        euint64 assets = FHE.fromExternal(encAssets, assetsProof);

        allotments[id] = CareAllotment({
            resident: msg.sender,
            careHome: careHome,
            monthlyFee: FHE.asEuint64(0),
            subsidy: FHE.asEuint64(0),
            copayment: FHE.asEuint64(0),
            assetsMeansTest: assets,
            needScore: FHE.asEuint32(0),
            assessmentDate: block.timestamp,
            admissionDate: 0,
            status: AllotmentStatus.Pending
        });

        FHE.allowThis(allotments[id].assetsMeansTest);
        FHE.allowThis(allotments[id].monthlyFee);
        FHE.allowThis(allotments[id].subsidy);
        FHE.allowThis(allotments[id].copayment);
        FHE.allowThis(allotments[id].needScore);

        residentAllotment[msg.sender] = id;
        emit AllotmentRequested(id, msg.sender, careHome);
    }

    function conductMeansTest(
        uint256 id,
        externalEuint32 encNeedScore,
        bytes calldata scoreProof,
        externalEuint64 encMonthlyFee,
        bytes calldata feeProof,
        externalEuint64 encSubsidy,
        bytes calldata subsidyProof
    ) external onlyRole(SOCIAL_WORKER_ROLE) {
        CareAllotment storage a = allotments[id];
        require(a.status == AllotmentStatus.Pending, "Not pending");

        a.needScore = FHE.fromExternal(encNeedScore, scoreProof);
        a.monthlyFee = FHE.fromExternal(encMonthlyFee, feeProof);
        a.subsidy = FHE.fromExternal(encSubsidy, subsidyProof);
        a.copayment = FHE.sub(a.monthlyFee, a.subsidy);

        FHE.allowThis(a.needScore);
        FHE.allowThis(a.monthlyFee);
        FHE.allow(a.monthlyFee, a.careHome);
        FHE.allowThis(a.subsidy);
        FHE.allowThis(a.copayment);
        FHE.allow(a.copayment, a.resident);

        a.status = AllotmentStatus.Assessed;
        emit MeansTestCompleted(id);
    }

    function approveAllotment(uint256 id) external onlyRole(FINANCE_ROLE) {
        CareAllotment storage a = allotments[id];
        require(a.status == AllotmentStatus.Assessed, "Not assessed");
        a.status = AllotmentStatus.Approved;
        FHE.allow(a.subsidy, msg.sender);
        emit AllotmentApproved(id);
    }

    function admitResident(uint256 id) external onlyRole(CARE_HOME_ROLE) {
        CareAllotment storage a = allotments[id];
        require(a.status == AllotmentStatus.Approved, "Not approved");
        require(msg.sender == a.careHome, "Wrong care home");
        a.admissionDate = block.timestamp;
        a.status = AllotmentStatus.Active;
        emit ResidentAdmitted(id);
    }

    function dischargeResident(uint256 id) external {
        CareAllotment storage a = allotments[id];
        require(msg.sender == a.careHome || hasRole(SOCIAL_WORKER_ROLE, msg.sender), "Unauthorized");
        require(a.status == AllotmentStatus.Active, "Not active");
        a.status = AllotmentStatus.Discharged;
        emit ResidentDischarged(id);
    }

    function allowResidentView(uint256 id, address viewer) external {
        CareAllotment storage a = allotments[id];
        require(msg.sender == a.resident, "Not resident");
        FHE.allow(a.copayment, viewer);
        FHE.allow(a.needScore, viewer);
    }
}
