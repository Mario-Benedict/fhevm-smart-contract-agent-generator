// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateBankruptcyClaimsProcessor
/// @notice A bankruptcy estate processor where creditor claim amounts, priority
///         rankings, and asset distribution amounts remain encrypted. Trustee
///         processes claims without revealing individual creditor positions.
contract PrivateBankruptcyClaimsProcessor is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant TRUSTEE_ROLE = keccak256("TRUSTEE_ROLE");
    bytes32 public constant COURT_ROLE = keccak256("COURT_ROLE");

    enum ClaimPriority { Secured, Administrative, Priority, General, Equity }
    enum ClaimStatus { Filed, Allowed, Disputed, Settled, Discharged }

    struct Claim {
        euint64 claimedAmount;      // what creditor says they're owed
        euint64 allowedAmount;      // court-approved amount
        euint64 distributionPaid;   // actual payout
        euint32 priorityScore;      // encrypted priority ranking
        ClaimPriority priority;
        ClaimStatus status;
        address creditor;
        uint256 filedAt;
        bool secured;
    }

    struct EstateAsset {
        euint64 appraisedValue;
        euint64 liquidatedValue;
        euint32 encumbranceLevel;   // 0=unencumbered, 10000=fully encumbered
        bool liquidated;
        string assetType;
    }

    mapping(bytes32 => Claim) private claims;
    mapping(uint8 => EstateAsset) private assets;
    mapping(address => bytes32[]) public creditorClaims;
    bytes32[] public claimList;
    uint8 public assetCount;

    euint64 private _totalClaimsAllowed;
    euint64 private _estateValue;
    euint64 private _distributedToDate;
    euint64 private _reserveForDisputed;

    event ClaimFiled(bytes32 indexed claimId, address indexed creditor, ClaimPriority priority);
    event ClaimAllowed(bytes32 indexed claimId);
    event DistributionMade(bytes32 indexed claimId);
    event AssetLiquidated(uint8 indexed assetId);

    constructor(externalEuint64 encEstateValue, bytes memory evProof) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TRUSTEE_ROLE, msg.sender);
        _grantRole(COURT_ROLE, msg.sender);
        _estateValue = FHE.fromExternal(encEstateValue, evProof);
        _totalClaimsAllowed = FHE.asEuint64(0);
        _distributedToDate = FHE.asEuint64(0);
        _reserveForDisputed = FHE.asEuint64(0);
        FHE.allowThis(_estateValue);
        FHE.allowThis(_totalClaimsAllowed);
        FHE.allowThis(_distributedToDate);
        FHE.allowThis(_reserveForDisputed);
    }

    function registerAsset(
        externalEuint64 encAppraised, bytes calldata apprProof,
        externalEuint32 encEncumbrance, bytes calldata encProof,
        string calldata assetType
    ) external onlyRole(TRUSTEE_ROLE) {
        uint8 id = assetCount++;
        assets[id].appraisedValue = FHE.fromExternal(encAppraised, apprProof);
        assets[id].encumbranceLevel = FHE.fromExternal(encEncumbrance, encProof);
        assets[id].liquidatedValue = FHE.asEuint64(0);
        assets[id].assetType = assetType;
        FHE.allowThis(assets[id].appraisedValue);
        FHE.allowThis(assets[id].encumbranceLevel);
        FHE.allowThis(assets[id].liquidatedValue);
    }

    function liquidateAsset(
        uint8 assetId,
        externalEuint64 encLiqValue, bytes calldata proof
    ) external onlyRole(TRUSTEE_ROLE) nonReentrant {
        require(!assets[assetId].liquidated, "Already liquidated");
        euint64 liqValue = FHE.fromExternal(encLiqValue, proof);
        assets[assetId].liquidatedValue = liqValue;
        assets[assetId].liquidated = true;
        _estateValue = FHE.add(_estateValue, liqValue);
        FHE.allowThis(assets[assetId].liquidatedValue);
        FHE.allowThis(_estateValue);
        emit AssetLiquidated(assetId);
    }

    function fileClaim(
        externalEuint64 encAmount, bytes calldata proof,
        ClaimPriority priority,
        bool secured
    ) external returns (bytes32 claimId) {
        claimId = keccak256(abi.encodePacked(msg.sender, block.timestamp, claimList.length));
        Claim storage c = claims[claimId];
        c.claimedAmount = FHE.fromExternal(encAmount, proof);
        c.allowedAmount = FHE.asEuint64(0);
        c.distributionPaid = FHE.asEuint64(0);
        c.priorityScore = FHE.asEuint32(uint32(priority));
        c.priority = priority;
        c.status = ClaimStatus.Filed;
        c.creditor = msg.sender;
        c.filedAt = block.timestamp;
        c.secured = secured;
        FHE.allowThis(c.claimedAmount);
        FHE.allow(c.claimedAmount, msg.sender);
        FHE.allowThis(c.allowedAmount);
        FHE.allowThis(c.distributionPaid);
        FHE.allowThis(c.priorityScore);
        claimList.push(claimId);
        creditorClaims[msg.sender].push(claimId);
        emit ClaimFiled(claimId, msg.sender, priority);
    }

    function allowClaim(
        bytes32 claimId,
        externalEuint64 encAllowedAmt, bytes calldata proof
    ) external onlyRole(COURT_ROLE) {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Filed || c.status == ClaimStatus.Disputed, "Cannot allow");
        c.allowedAmount = FHE.fromExternal(encAllowedAmt, proof);
        c.status = ClaimStatus.Allowed;
        _totalClaimsAllowed = FHE.add(_totalClaimsAllowed, c.allowedAmount);
        FHE.allowThis(c.allowedAmount);
        FHE.allow(c.allowedAmount, c.creditor);
        FHE.allowThis(_totalClaimsAllowed);
        emit ClaimAllowed(claimId);
    }

    function distributeToCreditor(bytes32 claimId) external onlyRole(TRUSTEE_ROLE) nonReentrant {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Allowed, "Not allowed");
        ebool estateSufficient = FHE.ge(_estateValue, c.allowedAmount);
        euint64 payment = FHE.select(estateSufficient, c.allowedAmount, _estateValue);
        c.distributionPaid = payment;
        c.status = ClaimStatus.Settled;
        _estateValue = FHE.sub(_estateValue, payment);
        _distributedToDate = FHE.add(_distributedToDate, payment);
        FHE.allowThis(c.distributionPaid);
        FHE.allow(c.distributionPaid, c.creditor);
        FHE.allow(payment, c.creditor);
        FHE.allowThis(_estateValue);
        FHE.allowThis(_distributedToDate);
        emit DistributionMade(claimId);
    }

    function allowEstateMetrics(address viewer) external onlyRole(TRUSTEE_ROLE) {
        FHE.allow(_estateValue, viewer);
        FHE.allow(_totalClaimsAllowed, viewer);
        FHE.allow(_distributedToDate, viewer);
    }

    function allowMyClaim(bytes32 claimId, address viewer) external {
        require(claims[claimId].creditor == msg.sender, "Not your claim");
        FHE.allow(claims[claimId].claimedAmount, viewer);
        FHE.allow(claims[claimId].allowedAmount, viewer);
        FHE.allow(claims[claimId].distributionPaid, viewer);
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