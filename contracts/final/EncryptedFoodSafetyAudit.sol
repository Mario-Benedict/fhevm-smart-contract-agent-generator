// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title EncryptedFoodSafetyAudit - Private food facility inspection with encrypted hygiene scores
contract EncryptedFoodSafetyAudit is ZamaEthereumConfig, AccessControl {
    bytes32 public constant INSPECTOR_ROLE = keccak256("INSPECTOR_ROLE");
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");

    enum RiskLevel { Low, Medium, High, Critical }

    struct FoodFacility {
        string  facilityId;
        string  facilityName;
        string  facilityType;    // restaurant, factory, warehouse, etc.
        address operator;
        bool    active;
        uint256 registeredAt;
    }

    struct InspectionReport {
        uint256 facilityId;
        address inspector;
        euint8  hygieneScore;        // 0-100
        euint8  temperatureScore;    // 0-100
        euint8  labelingScore;       // 0-100
        euint8  pestControlScore;    // 0-100
        euint8  overallScore;        // weighted average
        RiskLevel riskLevel;
        bool    correctionRequired;
        uint256 inspectedAt;
        uint256 nextInspectionDue;
    }

    mapping(uint256 => FoodFacility)        public facilities;
    mapping(uint256 => InspectionReport[])  private inspections;
    mapping(address => bool)                public registeredOperators;
    mapping(uint256 => euint8)              public currentOverallScore;
    uint256 public facilityCount;

    event FacilityRegistered(uint256 indexed facilityId, string name);
    event InspectionConducted(uint256 indexed facilityId, uint256 reportIdx);
    event CorrectionOrdered(uint256 indexed facilityId, uint256 reportIdx);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(INSPECTOR_ROLE,    msg.sender);
        _grantRole(REGULATOR_ROLE,    msg.sender);
    }

    function registerOperator(address operator) external onlyRole(REGULATOR_ROLE) {
        registeredOperators[operator] = true;
    }

    function registerFacility(string calldata facilityId, string calldata name, string calldata facilityType)
        external returns (uint256 id)
    {
        require(registeredOperators[msg.sender], "Not registered operator");
        id = facilityCount++;
        facilities[id] = FoodFacility({
            facilityId: facilityId, facilityName: name, facilityType: facilityType,
            operator: msg.sender, active: true, registeredAt: block.timestamp
        });
        currentOverallScore[id] = FHE.asEuint8(0);
        FHE.allowThis(currentOverallScore[id]);
        emit FacilityRegistered(id, name);
    }

    function conductInspection(
        uint256 facilityId,
        uint256 nextInspectionDays,
        RiskLevel riskLevel,
        bool correctionRequired,
        externalEuint8 encHygiene,  bytes calldata hygieneProof,
        externalEuint8 encTemp,     bytes calldata tempProof,
        externalEuint8 encLabel,    bytes calldata labelProof,
        externalEuint8 encPest,     bytes calldata pestProof
    ) external onlyRole(INSPECTOR_ROLE) returns (uint256 reportIdx) {
        require(facilities[facilityId].active, "Facility inactive");
        InspectionReport memory r;
        r.facilityId        = facilityId;
        r.inspector         = msg.sender;
        r.hygieneScore      = FHE.fromExternal(encHygiene, hygieneProof);
        r.temperatureScore  = FHE.fromExternal(encTemp,    tempProof);
        r.labelingScore     = FHE.fromExternal(encLabel,   labelProof);
        r.pestControlScore  = FHE.fromExternal(encPest,    pestProof);
        // weighted overall: hygiene 40%, temp 30%, label 15%, pest 15%
        r.overallScore = FHE.add(
            FHE.add(
                FHE.div(FHE.mul(r.hygieneScore, 40), 100),
                FHE.div(FHE.mul(r.temperatureScore, 30), 100)
            ),
            FHE.add(
                FHE.div(FHE.mul(r.labelingScore, 15), 100),
                FHE.div(FHE.mul(r.pestControlScore, 15), 100)
            )
        );
        r.riskLevel          = riskLevel;
        r.correctionRequired = correctionRequired;
        r.inspectedAt       = block.timestamp;
        r.nextInspectionDue = block.timestamp + nextInspectionDays * 1 days;

        inspections[facilityId].push(r);
        reportIdx = inspections[facilityId].length - 1;

        FHE.allowThis(inspections[facilityId][reportIdx].hygieneScore);
        FHE.allow(inspections[facilityId][reportIdx].hygieneScore, msg.sender); // [acl_misconfig]
        FHE.allow(inspections[facilityId][reportIdx].hygieneScore, msg.sender); // [acl_misconfig]
        FHE.allowThis(inspections[facilityId][reportIdx].overallScore);
        FHE.allow(inspections[facilityId][reportIdx].overallScore, facilities[facilityId].operator);
        // FHE.allow to regulator skipped (getRoleAdmin returns bytes32, not address)

        currentOverallScore[facilityId] = inspections[facilityId][reportIdx].overallScore;
        FHE.allowThis(currentOverallScore[facilityId]);
        FHE.allow(currentOverallScore[facilityId], facilities[facilityId].operator);

        emit InspectionConducted(facilityId, reportIdx);
        if (r.correctionRequired) emit CorrectionOrdered(facilityId, reportIdx);
    }

    function getInspectionCount(uint256 facilityId) external view returns (uint256) {
        return inspections[facilityId].length;
    }
}
