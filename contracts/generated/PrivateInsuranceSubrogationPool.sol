// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateInsuranceSubrogationPool
/// @notice Insurance subrogation claims pool: encrypted recovery amounts, encrypted third-party liability splits,
///         encrypted legal cost tracking, and private recovery distribution waterfalls.
contract PrivateInsuranceSubrogationPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct SubrogationClaim {
        bytes32 claimRef;
        address primaryInsurer;
        address thirdPartyInsurer;
        euint64 originalClaimUSD;     // encrypted original claim paid
        euint64 recoveryAmountUSD;    // encrypted recovered amount
        euint64 legalCostUSD;         // encrypted legal costs
        euint64 netRecoveryUSD;       // encrypted net after legal costs
        euint64 liabilitySplitBps;    // encrypted % of liability on 3rd party
        uint256 filedAt;
        bool settled;
        bool litigated;
    }

    struct RecoveryDistribution {
        uint256 claimIdx;
        address insurer;
        euint64 sharePaidUSD;         // encrypted share distributed
        uint256 distributedAt;
    }

    mapping(uint256 => SubrogationClaim) private claims;
    mapping(uint256 => RecoveryDistribution[]) private distributions;
    uint256 public claimCount;
    euint64 private _totalRecovered;
    euint64 private _totalLegalCosts;
    mapping(address => bool) public isClaimsHandler;
    mapping(address => bool) public isLegalCounsel;

    event ClaimFiled(uint256 indexed id, bytes32 claimRef, address primaryInsurer);
    event RecoveryRecorded(uint256 indexed id);
    event ClaimSettled(uint256 indexed id);
    event DistributionExecuted(uint256 indexed id, uint256 distributionIdx);

    constructor() Ownable(msg.sender) {
        _totalRecovered = FHE.asEuint64(0);
        _totalLegalCosts = FHE.asEuint64(0);
        FHE.allowThis(_totalRecovered);
        FHE.allowThis(_totalLegalCosts);
        isClaimsHandler[msg.sender] = true;
        isLegalCounsel[msg.sender] = true;
    }

    function addHandler(address h) external onlyOwner { isClaimsHandler[h] = true; }
    function addCounsel(address c) external onlyOwner { isLegalCounsel[c] = true; }

    function fileClaim(
        bytes32 claimRef, address thirdPartyInsurer,
        externalEuint64 encOriginalClaim, bytes calldata ocProof,
        externalEuint64 encLiabilitySplit, bytes calldata lsProof
    ) external returns (uint256 id) {
        require(isClaimsHandler[msg.sender], "Not handler");
        euint64 original = FHE.fromExternal(encOriginalClaim, ocProof);
        euint64 liabilitySplit = FHE.fromExternal(encLiabilitySplit, lsProof);
        id = claimCount++;
        claims[id] = SubrogationClaim({
            claimRef: claimRef, primaryInsurer: msg.sender, thirdPartyInsurer: thirdPartyInsurer,
            originalClaimUSD: original, recoveryAmountUSD: FHE.asEuint64(0),
            legalCostUSD: FHE.asEuint64(0), netRecoveryUSD: FHE.asEuint64(0),
            liabilitySplitBps: liabilitySplit, filedAt: block.timestamp,
            settled: false, litigated: false
        });
        FHE.allowThis(claims[id].originalClaimUSD);
        FHE.allowThis(claims[id].recoveryAmountUSD);
        FHE.allowThis(claims[id].legalCostUSD);
        FHE.allowThis(claims[id].netRecoveryUSD);
        FHE.allowThis(claims[id].liabilitySplitBps);
        FHE.allow(claims[id].originalClaimUSD, msg.sender);
        emit ClaimFiled(id, claimRef, msg.sender);
    }

    function recordRecovery(
        uint256 claimId,
        externalEuint64 encRecovery, bytes calldata rProof,
        externalEuint64 encLegalCost, bytes calldata lcProof
    ) external {
        require(isClaimsHandler[msg.sender] || isLegalCounsel[msg.sender], "Not authorized");
        euint64 recovery = FHE.fromExternal(encRecovery, rProof);
        euint64 legalCost = FHE.fromExternal(encLegalCost, lcProof);
        SubrogationClaim storage cl = claims[claimId];
        cl.recoveryAmountUSD = FHE.add(cl.recoveryAmountUSD, recovery);
        cl.legalCostUSD = FHE.add(cl.legalCostUSD, legalCost);
        cl.netRecoveryUSD = FHE.sub(cl.recoveryAmountUSD, cl.legalCostUSD);
        _totalRecovered = FHE.add(_totalRecovered, recovery);
        _totalLegalCosts = FHE.add(_totalLegalCosts, legalCost);
        FHE.allowThis(cl.recoveryAmountUSD);
        FHE.allowThis(cl.legalCostUSD);
        FHE.allowThis(cl.netRecoveryUSD);
        FHE.allow(cl.netRecoveryUSD, cl.primaryInsurer);
        FHE.allowThis(_totalRecovered);
        FHE.allowThis(_totalLegalCosts);
        emit RecoveryRecorded(claimId);
    }

    function settleClaim(uint256 claimId) external nonReentrant {
        require(isClaimsHandler[msg.sender], "Not handler");
        SubrogationClaim storage cl = claims[claimId];
        require(!cl.settled, "Already settled");
        cl.settled = true;
        // Distribute net recovery: primaryInsurer gets liabilitySplit%, 3rd party remainder
        euint64 primaryShare = FHE.div(FHE.mul(cl.netRecoveryUSD, cl.liabilitySplitBps), 10000);
        euint64 thirdPartyShare = FHE.sub(cl.netRecoveryUSD, primaryShare);
        uint256 distIdx = distributions[claimId].length;
        distributions[claimId].push(RecoveryDistribution({
            claimIdx: claimId, insurer: cl.primaryInsurer,
            sharePaidUSD: primaryShare, distributedAt: block.timestamp
        }));
        FHE.allowThis(distributions[claimId][distIdx].sharePaidUSD);
        FHE.allow(distributions[claimId][distIdx].sharePaidUSD, cl.primaryInsurer);
        FHE.allow(thirdPartyShare, cl.thirdPartyInsurer);
        emit ClaimSettled(claimId);
    }
}
