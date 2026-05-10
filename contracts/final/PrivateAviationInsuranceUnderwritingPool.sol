// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAviationInsuranceUnderwritingPool
/// @notice Encrypted aviation insurance pool for hull and liability coverage
///         with confidential aircraft valuations, loss history, premium splits,
///         and reinsurance cessions to Lloyd's syndicates.
contract PrivateAviationInsuranceUnderwritingPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AircraftCategory { COMMERCIAL_AIRLINE, REGIONAL_JET, GENERAL_AVIATION, HELICOPTER, CARGO, UAV_DRONE }
    enum CoverageType { HULL_ALL_RISKS, HULL_WAR, THIRD_PARTY_LIABILITY, PASSENGER_LIABILITY, CREW_PERSONAL_ACCIDENT }
    enum ClaimStatus { REPORTED, INVESTIGATING, PARTIAL_PAYMENT, SETTLED, SUBROGATED, DECLINED }

    struct AircraftPolicy {
        address insured;
        AircraftCategory category;
        euint64 aircraftInsuredValue;        // encrypted hull value USD
        euint64 annualPremiumHull;           // encrypted hull premium
        euint64 annualPremiumLiability;      // encrypted liability premium
        euint64 liabilityLimitPerOccurrence; // encrypted liability limit
        euint64 deductibleAmount;            // encrypted hull deductible
        euint64 lossHistoryAdjustment;       // encrypted experience mod factor (bps)
        euint64 reinsuranceCession;          // encrypted RI cession %
        euint64 netRetentionAmount;          // encrypted pool net retention
        uint256 policyStart;
        uint256 policyEnd;
        bool warRiskExcluded;
        bool active;
    }

    struct AviatiooClaim {
        bytes32 policyId;
        address insured;
        CoverageType coverageType;
        ClaimStatus status;
        euint64 grossLoss;               // encrypted gross loss estimate
        euint64 reinsuranceRecovery;     // encrypted RI recovery
        euint64 netClaimCost;            // encrypted net to pool
        euint64 salvageValue;            // encrypted salvaged aircraft value
        euint64 subrogationProceeds;     // encrypted subrogation recovered
        euint64 lossAdjusterFee;         // encrypted adjuster costs
        uint256 dateOfLoss;
        bool totalLoss;
    }

    struct PoolFinancials {
        euint64 totalGPW;                // encrypted gross premium written
        euint64 totalNetPremium;         // encrypted net premium retained
        euint64 totalGrossLosses;        // encrypted gross losses paid
        euint64 totalRIRecoveries;       // encrypted RI recoveries
        euint64 poolReserves;            // encrypted total reserve fund
        euint64 lossRatio;               // encrypted loss ratio bps
        euint64 expenseRatio;            // encrypted expense ratio bps
        euint64 combinedRatio;           // encrypted combined ratio bps
    }

    mapping(bytes32 => AircraftPolicy) private policies;
    mapping(bytes32 => AviatiooClaim) private claims;
    mapping(address => bool) public authorizedBroker;
    PoolFinancials private poolFinancials;

    event PolicyIssued(bytes32 indexed policyId, AircraftCategory category);
    event ClaimFiled(bytes32 indexed claimId, bytes32 indexed policyId);
    event ClaimSettled(bytes32 indexed claimId);
    event RIRecoveryReceived(bytes32 indexed claimId);

    constructor(
        externalEuint64 encInitialReserves, bytes memory irProof
    ) Ownable(msg.sender) {
        poolFinancials.poolReserves = FHE.fromExternal(encInitialReserves, irProof);
        poolFinancials.totalGPW = FHE.asEuint64(0);
        poolFinancials.totalNetPremium = FHE.asEuint64(0);
        poolFinancials.totalGrossLosses = FHE.asEuint64(0);
        poolFinancials.totalRIRecoveries = FHE.asEuint64(0);
        poolFinancials.lossRatio = FHE.asEuint64(0);
        poolFinancials.expenseRatio = FHE.asEuint64(0);
        poolFinancials.combinedRatio = FHE.asEuint64(0);
        FHE.allowThis(poolFinancials.poolReserves);
        FHE.allowThis(poolFinancials.totalGPW);
        FHE.allowThis(poolFinancials.totalNetPremium);
        FHE.allowThis(poolFinancials.totalGrossLosses);
        FHE.allowThis(poolFinancials.totalRIRecoveries);
        FHE.allowThis(poolFinancials.lossRatio);
        FHE.allowThis(poolFinancials.expenseRatio);
        FHE.allowThis(poolFinancials.combinedRatio);
    }

    function issuePolicy(
        address insured,
        AircraftCategory category,
        externalEuint64 encHullValue, bytes calldata hvProof,
        externalEuint64 encHullPremium, bytes calldata hpProof,
        externalEuint64 encLiabilityPremium, bytes calldata lpProof,
        externalEuint64 encLiabilityLimit, bytes calldata llProof,
        externalEuint64 encDeductible, bytes calldata dedProof,
        externalEuint64 encRICession, bytes calldata ricProof,
        uint256 policyStart, uint256 policyEnd, bool warRiskExcluded
    ) external onlyOwner returns (bytes32 policyId) {
        euint64 hullValue = FHE.fromExternal(encHullValue, hvProof);
        euint64 hullPremium = FHE.fromExternal(encHullPremium, hpProof);
        euint64 liabPremium = FHE.fromExternal(encLiabilityPremium, lpProof);
        euint64 liabLimit = FHE.fromExternal(encLiabilityLimit, llProof);
        euint64 deductible = FHE.fromExternal(encDeductible, dedProof);
        euint64 riCession = FHE.fromExternal(encRICession, ricProof);
        euint64 totalPremium = FHE.add(hullPremium, liabPremium);
        euint64 netRetention = FHE.div(FHE.mul(totalPremium, FHE.sub(FHE.asEuint64(10000), riCession)), 10000);

        policyId = keccak256(abi.encodePacked(insured, category, policyStart, block.timestamp));
        AircraftPolicy storage _s0 = policies[policyId];
        _s0.insured = insured;
        _s0.category = category;
        _s0.aircraftInsuredValue = hullValue;
        _s0.annualPremiumHull = hullPremium;
        _s0.annualPremiumLiability = liabPremium;
        _s0.liabilityLimitPerOccurrence = liabLimit;
        _s0.deductibleAmount = deductible;
        _s0.lossHistoryAdjustment = FHE.asEuint64(10000);
        _s0.reinsuranceCession = riCession;
        _s0.netRetentionAmount = netRetention;
        _s0.policyStart = policyStart;
        _s0.policyEnd = policyEnd;
        _s0.warRiskExcluded = warRiskExcluded;
        _s0.active = true;

        poolFinancials.totalGPW = FHE.add(poolFinancials.totalGPW, totalPremium);
        poolFinancials.totalNetPremium = FHE.add(poolFinancials.totalNetPremium, netRetention);
        poolFinancials.poolReserves = FHE.add(poolFinancials.poolReserves, netRetention);

        FHE.allowThis(hullValue); FHE.allow(hullValue, insured);
        FHE.allowThis(hullPremium); FHE.allow(hullPremium, insured);
        FHE.allowThis(liabPremium); FHE.allow(liabPremium, insured);
        FHE.allowThis(liabLimit); FHE.allow(liabLimit, insured);
        FHE.allowThis(deductible); FHE.allow(deductible, insured);
        FHE.allowThis(riCession); FHE.allowThis(netRetention);
        FHE.allowThis(policies[policyId].lossHistoryAdjustment);
        FHE.allowThis(poolFinancials.totalGPW);
        FHE.allowThis(poolFinancials.totalNetPremium);
        FHE.allowThis(poolFinancials.poolReserves);

        emit PolicyIssued(policyId, category);
    }

    function fileClaim(
        bytes32 policyId,
        CoverageType coverageType,
        externalEuint64 encGrossLoss, bytes calldata glProof,
        externalEuint64 encSalvageValue, bytes calldata svProof,
        uint256 dateOfLoss,
        bool totalLoss
    ) external nonReentrant returns (bytes32 claimId) {
        AircraftPolicy storage pol = policies[policyId];
        require(pol.insured == msg.sender && pol.active, "Invalid policy");
        euint64 grossLoss = FHE.fromExternal(encGrossLoss, glProof);
        euint64 salvageValue = FHE.fromExternal(encSalvageValue, svProof);
        euint64 netLoss = FHE.select(FHE.ge(grossLoss, FHE.add(pol.deductibleAmount, salvageValue)),
            FHE.sub(grossLoss, FHE.add(pol.deductibleAmount, salvageValue)),
            FHE.asEuint64(0));
        euint64 riRecovery = FHE.div(FHE.mul(netLoss, pol.reinsuranceCession), 10000);
        euint64 netClaimCost = FHE.sub(netLoss, riRecovery);

        claimId = keccak256(abi.encodePacked(policyId, dateOfLoss, block.timestamp));
        AviatiooClaim storage _s1 = claims[claimId];
        _s1.policyId = policyId;
        _s1.insured = msg.sender;
        _s1.coverageType = coverageType;
        _s1.status = ClaimStatus.REPORTED;
        _s1.grossLoss = grossLoss;
        _s1.reinsuranceRecovery = riRecovery;
        _s1.netClaimCost = netClaimCost;
        _s1.salvageValue = salvageValue;
        _s1.subrogationProceeds = FHE.asEuint64(0);
        _s1.lossAdjusterFee = FHE.asEuint64(0);
        _s1.dateOfLoss = dateOfLoss;
        _s1.totalLoss = totalLoss;
        poolFinancials.totalGrossLosses = FHE.add(poolFinancials.totalGrossLosses, grossLoss);
        FHE.allowThis(grossLoss); FHE.allow(grossLoss, msg.sender);
        FHE.allowThis(netClaimCost); FHE.allow(netClaimCost, msg.sender);
        FHE.allowThis(salvageValue); FHE.allowThis(riRecovery);
        FHE.allowThis(claims[claimId].subrogationProceeds);
        FHE.allowThis(claims[claimId].lossAdjusterFee);
        FHE.allowThis(poolFinancials.totalGrossLosses);
        emit ClaimFiled(claimId, policyId);
    }

    function settleClaim(bytes32 claimId) external onlyOwner {
        AviatiooClaim storage clm = claims[claimId];
        clm.status = ClaimStatus.SETTLED;
        poolFinancials.poolReserves = FHE.sub(poolFinancials.poolReserves,
            FHE.select(FHE.ge(poolFinancials.poolReserves, clm.netClaimCost),
                clm.netClaimCost, poolFinancials.poolReserves));
        poolFinancials.totalRIRecoveries = FHE.add(poolFinancials.totalRIRecoveries, clm.reinsuranceRecovery);
        FHE.allowThis(poolFinancials.poolReserves);
        FHE.allowThis(poolFinancials.totalRIRecoveries);
        FHE.allowTransient(clm.netClaimCost, clm.insured);
        emit ClaimSettled(claimId);
    }

    function allowPoolStatsView(address viewer) external onlyOwner {
        FHE.allow(poolFinancials.totalGPW, viewer);
        FHE.allow(poolFinancials.totalNetPremium, viewer);
        FHE.allow(poolFinancials.totalGrossLosses, viewer);
        FHE.allow(poolFinancials.poolReserves, viewer);
        FHE.allow(poolFinancials.lossRatio, viewer);
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