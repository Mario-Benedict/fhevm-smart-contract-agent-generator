// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCarbonBudgetRegistry
/// @notice National/corporate carbon budget registry: encrypted annual emission
///         allowances, private inter-company transfers, and confidential offset credits.
///         Designed for compliance with regulated cap-and-trade frameworks.
contract EncryptedCarbonBudgetRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    struct EntityAccount {
        euint64 annualCap;           // encrypted tonne CO2e allowance
        euint64 actualEmissions;     // encrypted actual emissions reported
        euint64 offsetCredits;       // encrypted offset credits held
        euint64 bankedCredits;       // encrypted surplus credits banked from prior years
        euint32 complianceScore;     // encrypted compliance score (0-100)
        bool registered;
        bool suspended;
    }

    struct AllowanceTransfer {
        address from;
        address to;
        euint64 amount;      // encrypted transfer amount
        uint256 timestamp;
        bool completed;
    }

    struct OffsetIssuance {
        address projectOwner;
        euint64 creditsIssued;   // encrypted credits
        euint64 vintageYear;     // encrypted vintage year
        bytes32 projectId;
        bool verified;
    }

    mapping(address => EntityAccount) private entities;
    mapping(uint256 => AllowanceTransfer) private transfers;
    mapping(uint256 => OffsetIssuance) private offsets;
    mapping(address => bool) public isVerifier;
    mapping(address => bool) public isRegulator;

    uint256 public transferCount;
    uint256 public offsetCount;
    euint64 private _totalNationalCap;
    euint64 private _totalNationalEmissions;
    euint64 private _penaltyRatePerTonne; // encrypted penalty rate

    event EntityRegistered(address indexed entity);
    event EmissionsReported(address indexed entity, uint256 period);
    event AllowanceTransferred(uint256 indexed transferId);
    event OffsetIssued(uint256 indexed offsetId, address indexed owner);
    event OffsetRetired(address indexed entity, uint256 indexed offsetId);
    event ComplianceDetermined(address indexed entity, bool compliant);

    constructor(
        externalEuint64 encNationalCap, bytes memory ncProof,
        externalEuint64 encPenaltyRate, bytes memory prProof
    ) Ownable(msg.sender) {
        _totalNationalCap = FHE.fromExternal(encNationalCap, ncProof);
        _penaltyRatePerTonne = FHE.fromExternal(encPenaltyRate, prProof);
        _totalNationalEmissions = FHE.asEuint64(0);
        FHE.allowThis(_totalNationalCap);
        FHE.allowThis(_penaltyRatePerTonne);
        FHE.allowThis(_totalNationalEmissions);
        isRegulator[msg.sender] = true;
    }

    modifier onlyRegulator() { require(isRegulator[msg.sender], "Not regulator"); _; }
    modifier onlyVerifier() { require(isVerifier[msg.sender], "Not verifier"); _; }

    function registerEntity(
        address entity,
        externalEuint64 encAnnualCap, bytes calldata acProof
    ) external onlyRegulator {
        require(!entities[entity].registered, "Already registered");
        EntityAccount storage ea = entities[entity];
        ea.annualCap = FHE.fromExternal(encAnnualCap, acProof);
        ea.actualEmissions = FHE.asEuint64(0);
        ea.offsetCredits = FHE.asEuint64(0);
        ea.bankedCredits = FHE.asEuint64(0);
        ea.complianceScore = FHE.asEuint32(100);
        ea.registered = true;
        ea.suspended = false;
        FHE.allowThis(ea.annualCap);
        FHE.allow(ea.annualCap, entity);
        FHE.allowThis(ea.actualEmissions);
        FHE.allow(ea.actualEmissions, entity);
        FHE.allowThis(ea.offsetCredits);
        FHE.allow(ea.offsetCredits, entity);
        FHE.allowThis(ea.bankedCredits);
        FHE.allow(ea.bankedCredits, entity);
        FHE.allowThis(ea.complianceScore);
        FHE.allow(ea.complianceScore, entity);
        emit EntityRegistered(entity);
    }

    function reportEmissions(
        externalEuint64 encEmissions, bytes calldata eProof,
        uint256 compliancePeriod
    ) external whenNotPaused {
        EntityAccount storage ea = entities[msg.sender];
        require(ea.registered && !ea.suspended, "Not eligible");
        euint64 reported = FHE.fromExternal(encEmissions, eProof);
        ea.actualEmissions = FHE.add(ea.actualEmissions, reported);
        _totalNationalEmissions = FHE.add(_totalNationalEmissions, reported);
        FHE.allowThis(ea.actualEmissions);
        FHE.allow(ea.actualEmissions, msg.sender);
        FHE.allowThis(_totalNationalEmissions);
        emit EmissionsReported(msg.sender, compliancePeriod);
    }

    function transferAllowance(
        address to,
        externalEuint64 encAmount, bytes calldata aProof
    ) external nonReentrant whenNotPaused returns (uint256 transferId) {
        EntityAccount storage fromEa = entities[msg.sender];
        EntityAccount storage toEa = entities[to];
        require(fromEa.registered && toEa.registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        // Check sender has sufficient cap to transfer
        ebool _safeSub167 = FHE.ge(fromEa.annualCap, fromEa.actualEmissions);
        euint64 availableCap = FHE.select(_safeSub167, FHE.sub(fromEa.annualCap, fromEa.actualEmissions), FHE.asEuint64(0));
        ebool hasSufficient = FHE.ge(availableCap, amount);
        euint64 actualTransfer = FHE.select(hasSufficient, amount, availableCap);
        ebool _safeSub168 = FHE.ge(fromEa.annualCap, actualTransfer);
        fromEa.annualCap = FHE.select(_safeSub168, FHE.sub(fromEa.annualCap, actualTransfer), FHE.asEuint64(0));
        toEa.annualCap = FHE.add(toEa.annualCap, actualTransfer);
        FHE.allowThis(fromEa.annualCap);
        FHE.allow(fromEa.annualCap, msg.sender);
        FHE.allowThis(toEa.annualCap);
        FHE.allow(toEa.annualCap, to);
        transferId = transferCount++;
        transfers[transferId] = AllowanceTransfer({
            from: msg.sender, to: to, amount: actualTransfer,
            timestamp: block.timestamp, completed: true
        });
        FHE.allowThis(transfers[transferId].amount);
        FHE.allow(transfers[transferId].amount, msg.sender);
        FHE.allow(transfers[transferId].amount, to);
        emit AllowanceTransferred(transferId);
    }

    function issueOffsetCredits(
        address projectOwner,
        externalEuint64 encCredits, bytes calldata cProof,
        externalEuint64 encVintage, bytes calldata vProof,
        bytes32 projectId
    ) external onlyVerifier returns (uint256 offsetId) {
        euint64 credits = FHE.fromExternal(encCredits, cProof);
        euint64 vintage = FHE.fromExternal(encVintage, vProof);
        offsetId = offsetCount++;
        offsets[offsetId] = OffsetIssuance({
            projectOwner: projectOwner, creditsIssued: credits,
            vintageYear: vintage, projectId: projectId, verified: true
        });
        entities[projectOwner].offsetCredits = FHE.add(entities[projectOwner].offsetCredits, credits);
        FHE.allowThis(offsets[offsetId].creditsIssued);
        FHE.allow(offsets[offsetId].creditsIssued, projectOwner);
        FHE.allowThis(entities[projectOwner].offsetCredits);
        FHE.allow(entities[projectOwner].offsetCredits, projectOwner);
        emit OffsetIssued(offsetId, projectOwner);
    }

    function retireOffsets(uint256 offsetId, externalEuint64 encRetireAmt, bytes calldata rProof) external {
        EntityAccount storage ea = entities[msg.sender];
        require(ea.registered, "Not registered");
        euint64 retireAmt = FHE.fromExternal(encRetireAmt, rProof);
        ebool hasCreds = FHE.ge(ea.offsetCredits, retireAmt);
        euint64 actual = FHE.select(hasCreds, retireAmt, ea.offsetCredits);
        ebool _safeSub169 = FHE.ge(ea.offsetCredits, actual);
        ea.offsetCredits = FHE.select(_safeSub169, FHE.sub(ea.offsetCredits, actual), FHE.asEuint64(0));
        // Offset actual emissions
        ebool hasEmissions = FHE.ge(ea.actualEmissions, actual);
        euint64 reduction = FHE.select(hasEmissions, actual, ea.actualEmissions);
        ebool _safeSub170 = FHE.ge(ea.actualEmissions, reduction);
        ea.actualEmissions = FHE.select(_safeSub170, FHE.sub(ea.actualEmissions, reduction), FHE.asEuint64(0));
        FHE.allowThis(ea.offsetCredits);
        FHE.allow(ea.offsetCredits, msg.sender);
        FHE.allowThis(ea.actualEmissions);
        FHE.allow(ea.actualEmissions, msg.sender);
        emit OffsetRetired(msg.sender, offsetId);
    }

    function bankSurplusCredits() external {
        EntityAccount storage ea = entities[msg.sender];
        require(ea.registered, "Not registered");
        ebool hasSurplus = FHE.gt(ea.annualCap, ea.actualEmissions);
        ebool _safeSub171 = FHE.ge(ea.annualCap, ea.actualEmissions);
        euint64 surplus = FHE.select(hasSurplus,
            FHE.select(_safeSub171, FHE.sub(ea.annualCap, ea.actualEmissions), FHE.asEuint64(0)),
            FHE.asEuint64(0));
        ea.bankedCredits = FHE.add(ea.bankedCredits, surplus);
        FHE.allowThis(ea.bankedCredits);
        FHE.allow(ea.bankedCredits, msg.sender);
    }

    function allowEntityDataToRegulator(address entity, address regulator) external onlyRegulator {
        EntityAccount storage ea = entities[entity];
        FHE.allow(ea.actualEmissions, regulator);
        FHE.allow(ea.annualCap, regulator);
        FHE.allow(ea.offsetCredits, regulator);
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function suspendEntity(address e) external onlyRegulator { entities[e].suspended = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
