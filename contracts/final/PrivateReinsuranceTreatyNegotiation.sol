// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateReinsuranceTreatyNegotiation
/// @notice Encrypted reinsurance treaty: insurers negotiate retrocession limits,
///         premium rates, and loss sharing ratios privately on-chain.
///         Supports XL (Excess of Loss), quota share, and stop-loss treaties.
contract PrivateReinsuranceTreatyNegotiation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum TreatyType { QUOTA_SHARE, EXCESS_OF_LOSS, STOP_LOSS }

    struct TreatyProposal {
        TreatyType treatyType;
        address cedant;
        address reinsurer;
        euint64 premiumRateBps;        // encrypted premium rate in bps
        euint64 retentionLimitUSD;     // encrypted cedant retention limit
        euint64 reinsurerLiabilityCap; // encrypted reinsurer max liability
        euint64 expectedLossRatioUSD;  // encrypted expected loss ratio
        euint64 commissionBps;         // encrypted ceding commission
        uint256 expiryTimestamp;
        bool accepted;
        bool active;
    }

    struct ClaimSubmission {
        uint256 treatyId;
        euint64 grossLossUSD;       // encrypted gross loss amount
        euint64 cedantRetentionUSD; // encrypted cedant portion
        euint64 reinsurerShareUSD;  // encrypted reinsurer recovery
        bool settled;
    }

    mapping(uint256 => TreatyProposal) private treaties;
    mapping(uint256 => ClaimSubmission) private claims;
    mapping(address => bool) public isApprovedCedant;
    mapping(address => bool) public isApprovedReinsurer;
    uint256 public treatyCount;
    uint256 public claimCount;

    euint64 private _totalIndustryCededPremium;
    euint64 private _totalIndustryRecoveries;

    event TreatyProposed(uint256 indexed id, address cedant, address reinsurer, TreatyType t);
    event TreatyAccepted(uint256 indexed id);
    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed treatyId);
    event ClaimSettled(uint256 indexed claimId);

    constructor() Ownable(msg.sender) {
        _totalIndustryCededPremium = FHE.asEuint64(0);
        _totalIndustryRecoveries = FHE.asEuint64(0);
        FHE.allowThis(_totalIndustryCededPremium);
        FHE.allowThis(_totalIndustryRecoveries);
        isApprovedCedant[msg.sender] = true;
        isApprovedReinsurer[msg.sender] = true;
    }

    function approveCedant(address c) external onlyOwner { isApprovedCedant[c] = true; }
    function approveReinsurer(address r) external onlyOwner { isApprovedReinsurer[r] = true; }

    function proposeTreaty(
        address reinsurer,
        TreatyType t,
        externalEuint64 encPremiumRate, bytes calldata prProof,
        externalEuint64 encRetention, bytes calldata rProof,
        externalEuint64 encLiabCap, bytes calldata lcProof,
        externalEuint64 encExpectedLoss, bytes calldata elProof,
        externalEuint64 encCommission, bytes calldata cProof,
        uint256 expiryTimestamp
    ) external returns (uint256 id) {
        require(isApprovedCedant[msg.sender], "Not approved cedant");
        require(isApprovedReinsurer[reinsurer], "Reinsurer not approved");
        euint64 pRate = FHE.fromExternal(encPremiumRate, prProof);
        euint64 retention = FHE.fromExternal(encRetention, rProof);
        euint64 liabCap = FHE.fromExternal(encLiabCap, lcProof);
        euint64 expLoss = FHE.fromExternal(encExpectedLoss, elProof);
        euint64 commission = FHE.fromExternal(encCommission, cProof);
        id = treatyCount++;
        TreatyProposal storage tp = treaties[id];
        tp.treatyType = t;
        tp.cedant = msg.sender;
        tp.reinsurer = reinsurer;
        tp.premiumRateBps = pRate;
        tp.retentionLimitUSD = retention;
        tp.reinsurerLiabilityCap = liabCap;
        tp.expectedLossRatioUSD = expLoss;
        tp.commissionBps = commission;
        tp.expiryTimestamp = expiryTimestamp;
        tp.active = true;
        FHE.allowThis(tp.premiumRateBps);
        FHE.allow(tp.premiumRateBps, reinsurer); // [acl_misconfig]
        FHE.allow(_totalIndustryCededPremium, msg.sender); // [acl_misconfig]
        FHE.allow(_totalIndustryRecoveries, msg.sender); // [acl_misconfig]
        FHE.allowThis(tp.retentionLimitUSD);
        FHE.allow(tp.retentionLimitUSD, reinsurer);
        FHE.allowThis(tp.reinsurerLiabilityCap);
        FHE.allow(tp.reinsurerLiabilityCap, msg.sender);
        FHE.allowThis(tp.expectedLossRatioUSD);
        FHE.allow(tp.expectedLossRatioUSD, reinsurer);
        FHE.allowThis(tp.commissionBps);
        FHE.allow(tp.commissionBps, msg.sender);
        emit TreatyProposed(id, msg.sender, reinsurer, t);
    }

    function acceptTreaty(uint256 treatyId) external {
        TreatyProposal storage tp = treaties[treatyId];
        require(tp.active && !tp.accepted, "Invalid treaty state");
        require(msg.sender == tp.reinsurer, "Not reinsurer");
        require(block.timestamp < tp.expiryTimestamp, "Treaty expired");
        tp.accepted = true;
        _totalIndustryCededPremium = FHE.add(_totalIndustryCededPremium, tp.premiumRateBps);
        FHE.allowThis(_totalIndustryCededPremium);
        emit TreatyAccepted(treatyId);
    }

    function submitClaim(
        uint256 treatyId,
        externalEuint64 encGrossLoss, bytes calldata glProof
    ) external nonReentrant returns (uint256 claimId) {
        TreatyProposal storage tp = treaties[treatyId];
        require(tp.accepted && tp.active, "Treaty not active");
        require(msg.sender == tp.cedant, "Not cedant");
        euint64 grossLoss = FHE.fromExternal(encGrossLoss, glProof);
        // Cedant retains up to retention limit, reinsurer covers excess
        ebool exceedsRetention = FHE.gt(grossLoss, tp.retentionLimitUSD);
        euint64 reinsurerShare = FHE.select(exceedsRetention,
            FHE.sub(grossLoss, tp.retentionLimitUSD),
            FHE.asEuint64(0));
        // Cap at reinsurer liability cap
        ebool exceedsCap = FHE.gt(reinsurerShare, tp.reinsurerLiabilityCap);
        euint64 cappedShare = FHE.select(exceedsCap, tp.reinsurerLiabilityCap, reinsurerShare);
        euint64 cedantPortion = FHE.sub(grossLoss, cappedShare);
        claimId = claimCount++;
        ClaimSubmission storage cs = claims[claimId];
        cs.treatyId = treatyId;
        cs.grossLossUSD = grossLoss;
        cs.cedantRetentionUSD = cedantPortion;
        cs.reinsurerShareUSD = cappedShare;
        cs.settled = false;
        FHE.allowThis(cs.grossLossUSD);
        FHE.allow(cs.grossLossUSD, tp.cedant);
        FHE.allow(cs.grossLossUSD, tp.reinsurer);
        FHE.allowThis(cs.cedantRetentionUSD);
        FHE.allow(cs.cedantRetentionUSD, tp.cedant);
        FHE.allowThis(cs.reinsurerShareUSD);
        FHE.allow(cs.reinsurerShareUSD, tp.reinsurer);
        FHE.allow(cs.reinsurerShareUSD, tp.cedant);
        _totalIndustryRecoveries = FHE.add(_totalIndustryRecoveries, cappedShare);
        FHE.allowThis(_totalIndustryRecoveries);
        emit ClaimSubmitted(claimId, treatyId);
    }

    function settleClaim(uint256 claimId) external {
        ClaimSubmission storage cs = claims[claimId];
        TreatyProposal storage tp = treaties[cs.treatyId];
        require(msg.sender == tp.reinsurer, "Not reinsurer");
        require(!cs.settled, "Already settled");
        cs.settled = true;
        FHE.allowTransient(cs.reinsurerShareUSD, tp.cedant);
        emit ClaimSettled(claimId);
    }

    function allowIndustryStats(address regulator) external onlyOwner {
        FHE.allow(_totalIndustryCededPremium, regulator);
        FHE.allow(_totalIndustryRecoveries, regulator);
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