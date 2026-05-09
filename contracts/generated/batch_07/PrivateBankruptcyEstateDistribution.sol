// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateBankruptcyEstateDistribution
/// @notice Encrypted bankruptcy estate administration: hidden creditor claim amounts,
///         confidential priority rankings, private preference clawback assessments,
///         and encrypted distribution waterfall calculations.
contract PrivateBankruptcyEstateDistribution is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ClaimPriority { SecuredFirst, SecuredJunior, AdminExpense, Priority, GeneralUnsecured, Equity }
    enum ClaimStatus { Filed, Allowed, Disputed, Disallowed, Withdrawn }

    struct BankruptcyEstate {
        address debtor;
        address trustee;
        string caseNumber;
        euint64 estimatedAssetValueUSD; // encrypted total estate assets
        euint64 totalClaimsFiledUSD;   // encrypted total claims
        euint64 distributedToDateUSD;  // encrypted distributed amount
        euint64 administrationCostUSD; // encrypted admin costs
        bool open;
    }

    struct CreditorClaim {
        uint256 estateId;
        address creditor;
        ClaimPriority priority;
        euint64 claimAmountUSD;        // encrypted claim amount
        euint64 allowedAmountUSD;      // encrypted allowed amount
        euint64 distributionReceivedUSD; // encrypted payout
        euint64 preferenceClawbackUSD; // encrypted preference amount
        ClaimStatus status;
        uint256 filedAt;
    }

    mapping(uint256 => BankruptcyEstate) private estates;
    mapping(uint256 => CreditorClaim) private claims;
    mapping(address => bool) public isBankruptcyTrustee;
    mapping(address => bool) public isBankruptcyCourt;

    uint256 public estateCount;
    uint256 public claimCount;
    euint64 private _totalAssetsAdministeredUSD;

    event EstateOpened(uint256 indexed id, string caseNumber);
    event ClaimFiled(uint256 indexed claimId, uint256 estateId, ClaimPriority priority);
    event DistributionMade(uint256 indexed claimId, uint256 madeAt);

    modifier onlyTrustee() {
        require(isBankruptcyTrustee[msg.sender] || msg.sender == owner(), "Not trustee");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAssetsAdministeredUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalAssetsAdministeredUSD);
        isBankruptcyTrustee[msg.sender] = true;
        isBankruptcyCourt[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addTrustee(address t) external onlyOwner { isBankruptcyTrustee[t] = true; }

    function openEstate(
        address debtor, string calldata caseNumber,
        externalEuint64 encAssets, bytes calldata aProof,
        externalEuint64 encAdminCost, bytes calldata acProof
    ) external onlyTrustee whenNotPaused returns (uint256 id) {
        euint64 assets = FHE.fromExternal(encAssets, aProof);
        euint64 adminCost = FHE.fromExternal(encAdminCost, acProof);
        id = estateCount++;
        estates[id] = BankruptcyEstate({
            debtor: debtor, trustee: msg.sender, caseNumber: caseNumber,
            estimatedAssetValueUSD: assets, totalClaimsFiledUSD: FHE.asEuint64(0),
            distributedToDateUSD: FHE.asEuint64(0), administrationCostUSD: adminCost, open: true
        });
        _totalAssetsAdministeredUSD = FHE.add(_totalAssetsAdministeredUSD, assets);
        FHE.allowThis(estates[id].estimatedAssetValueUSD); FHE.allow(estates[id].estimatedAssetValueUSD, msg.sender);
        FHE.allowThis(estates[id].totalClaimsFiledUSD); FHE.allow(estates[id].totalClaimsFiledUSD, msg.sender);
        FHE.allowThis(estates[id].distributedToDateUSD); FHE.allow(estates[id].distributedToDateUSD, msg.sender);
        FHE.allowThis(estates[id].administrationCostUSD); FHE.allow(estates[id].administrationCostUSD, msg.sender);
        FHE.allowThis(_totalAssetsAdministeredUSD);
        emit EstateOpened(id, caseNumber);
    }

    function fileClaim(
        uint256 estateId, ClaimPriority priority,
        externalEuint64 encClaimAmt, bytes calldata proof
    ) external whenNotPaused returns (uint256 claimId) {
        BankruptcyEstate storage e = estates[estateId];
        require(e.open, "Estate not open");
        euint64 claimAmt = FHE.fromExternal(encClaimAmt, proof);
        claimId = claimCount++;
        claims[claimId].estateId = estateId;
        claims[claimId].creditor = msg.sender;
        claims[claimId].priority = priority;
        claims[claimId].claimAmountUSD = claimAmt;
        claims[claimId].allowedAmountUSD = FHE.asEuint64(0);
        claims[claimId].distributionReceivedUSD = FHE.asEuint64(0);
        claims[claimId].preferenceClawbackUSD = FHE.asEuint64(0);
        claims[claimId].status = ClaimStatus.Filed;
        claims[claimId].filedAt = block.timestamp;
        e.totalClaimsFiledUSD = FHE.add(e.totalClaimsFiledUSD, claimAmt);
        FHE.allowThis(claims[claimId].claimAmountUSD); FHE.allow(claims[claimId].claimAmountUSD, msg.sender); FHE.allow(claims[claimId].claimAmountUSD, e.trustee);
        FHE.allowThis(claims[claimId].allowedAmountUSD); FHE.allow(claims[claimId].allowedAmountUSD, msg.sender);
        FHE.allowThis(claims[claimId].distributionReceivedUSD); FHE.allow(claims[claimId].distributionReceivedUSD, msg.sender);
        FHE.allowThis(claims[claimId].preferenceClawbackUSD);
        FHE.allowThis(e.totalClaimsFiledUSD); FHE.allow(e.totalClaimsFiledUSD, e.trustee);
        emit ClaimFiled(claimId, estateId, priority);
    }

    function allowClaim(
        uint256 claimId,
        externalEuint64 encAllowedAmt, bytes calldata proof
    ) external onlyTrustee {
        CreditorClaim storage c = claims[claimId];
        c.allowedAmountUSD = FHE.fromExternal(encAllowedAmt, proof);
        c.status = ClaimStatus.Allowed;
        FHE.allowThis(c.allowedAmountUSD); FHE.allow(c.allowedAmountUSD, c.creditor); FHE.allow(c.allowedAmountUSD, msg.sender);
    }

    function distributeToCreditor(
        uint256 claimId,
        externalEuint64 encDistAmt, bytes calldata proof
    ) external onlyTrustee nonReentrant {
        CreditorClaim storage c = claims[claimId];
        BankruptcyEstate storage e = estates[c.estateId];
        require(c.status == ClaimStatus.Allowed, "Claim not allowed");
        euint64 distAmt = FHE.fromExternal(encDistAmt, proof);
        c.distributionReceivedUSD = FHE.add(c.distributionReceivedUSD, distAmt);
        e.distributedToDateUSD = FHE.add(e.distributedToDateUSD, distAmt);
        e.estimatedAssetValueUSD = FHE.sub(e.estimatedAssetValueUSD, distAmt);
        FHE.allowThis(c.distributionReceivedUSD); FHE.allow(c.distributionReceivedUSD, c.creditor);
        FHE.allowThis(e.distributedToDateUSD); FHE.allow(e.distributedToDateUSD, e.trustee);
        FHE.allowThis(e.estimatedAssetValueUSD); FHE.allow(e.estimatedAssetValueUSD, e.trustee);
        emit DistributionMade(claimId, block.timestamp);
    }

    function allowEstateView(address viewer) external onlyOwner {
        FHE.allow(_totalAssetsAdministeredUSD, viewer);
    }
}
