// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePharmacyBenefitManagerRebate
/// @notice PBM rebate negotiations with encrypted drug list prices, rebate
///         amounts, formulary tier placements, and confidential utilization
///         data used in annual rebate settlement calculations.
contract PrivatePharmacyBenefitManagerRebate is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum FormularyTier { TIER_1_GENERIC, TIER_2_PREFERRED, TIER_3_NON_PREFERRED, TIER_4_SPECIALTY, EXCLUDED }
    enum ContractType { GUARANTEED_MINIMUM, MARKET_SHARE, PERFORMANCE_BASED, COMPETITIVE_DISPLACEMENT }
    enum SettlementStatus { PENDING, AUDITED, DISPUTED, SETTLED, PAID }

    struct DrugContract {
        address manufacturer;
        string ndcHash;               // hash of NDC code
        FormularyTier tier;
        ContractType contractType;
        euint64 listPrice;            // encrypted WAC list price per unit
        euint64 netPrice;             // encrypted net price after rebates
        euint64 guaranteedRebateBps;  // encrypted base rebate percentage
        euint64 performanceThreshold; // encrypted utilization target
        euint64 marketShareTarget;    // encrypted market share target (bps)
        euint64 currentMarketShare;   // encrypted achieved market share
        euint64 annualClaimsEstimate; // encrypted estimated annual claims
        uint256 contractStart;
        uint256 contractEnd;
        bool active;
    }

    struct RebateAccrual {
        bytes32 drugContractId;
        euint64 claimsVolume;          // encrypted total claims in period
        euint64 grossRebateAccrued;    // encrypted gross rebate amount
        euint64 performanceBonusAccrued;// encrypted performance bonus
        euint64 marketShareAdjustment; // encrypted market share adjustment
        euint64 netRebateDue;          // encrypted net rebate payable
        SettlementStatus status;
        uint256 periodStart;
        uint256 periodEnd;
    }

    struct PlanSponsorAccount {
        euint64 totalRebatesEarned;    // encrypted total rebates earned
        euint64 totalRebatesReceived;  // encrypted total rebates paid to plan
        euint64 pbmRetainedFees;       // encrypted PBM administrative fee retention
        euint64 passThroughAmount;     // encrypted amount passed to plan
        uint256 memberCount;
        bool transparencyModel;        // true = pass-through, false = traditional spread
    }

    mapping(bytes32 => DrugContract) private drugContracts;
    mapping(bytes32 => RebateAccrual) private accruals;
    mapping(address => PlanSponsorAccount) private planSponsors;
    mapping(address => bool) public authorizedManufacturer;
    mapping(address => bool) public authorizedPlanSponsor;

    euint64 private _totalRebatesNegotiated;   // encrypted total rebate pool
    euint64 private _totalPBMFees;             // encrypted total PBM revenue
    euint64 private _formularyRebatePool;      // encrypted total formulary rebates

    event DrugContractCreated(bytes32 indexed contractId, address manufacturer);
    event RebateAccrualRecorded(bytes32 indexed accrualId, bytes32 indexed contractId);
    event RebateSettled(bytes32 indexed accrualId, address planSponsor);
    event FormularyTierChanged(bytes32 indexed contractId, FormularyTier newTier);
    event PerformanceBonusTriggered(bytes32 indexed contractId);

    constructor() Ownable(msg.sender) {
        _totalRebatesNegotiated = FHE.asEuint64(0);
        _totalPBMFees = FHE.asEuint64(0);
        _formularyRebatePool = FHE.asEuint64(0);
        FHE.allowThis(_totalRebatesNegotiated);
        FHE.allowThis(_totalPBMFees);
        FHE.allowThis(_formularyRebatePool);
    }

    function negotiateDrugContract(
        address manufacturer,
        string calldata ndcHash,
        FormularyTier tier,
        ContractType contractType,
        externalEuint64 encListPrice, bytes calldata lpProof,
        externalEuint64 encRebateBps, bytes calldata rbProof,
        externalEuint64 encPerfThreshold, bytes calldata ptProof,
        externalEuint64 encMarketShareTarget, bytes calldata mstProof,
        externalEuint64 encAnnualClaims, bytes calldata acProof,
        uint256 contractEnd
    ) external onlyOwner returns (bytes32 contractId) {
        require(authorizedManufacturer[manufacturer], "Not authorized manufacturer");
        euint64 listPrice = FHE.fromExternal(encListPrice, lpProof);
        euint64 rebateBps = FHE.fromExternal(encRebateBps, rbProof);
        euint64 perfThreshold = FHE.fromExternal(encPerfThreshold, ptProof);
        euint64 marketShareTarget = FHE.fromExternal(encMarketShareTarget, mstProof);
        euint64 annualClaims = FHE.fromExternal(encAnnualClaims, acProof);

        euint64 netPrice = FHE.sub(listPrice, FHE.div(FHE.mul(listPrice, rebateBps), 10000));

        contractId = keccak256(abi.encodePacked(manufacturer, ndcHash, block.timestamp));

        DrugContract storage _s0 = drugContracts[contractId];
        _s0.manufacturer = manufacturer;
        _s0.ndcHash = ndcHash;
        _s0.tier = tier;
        _s0.contractType = contractType;
        _s0.listPrice = listPrice;
        _s0.netPrice = netPrice;
        _s0.guaranteedRebateBps = rebateBps;
        _s0.performanceThreshold = perfThreshold;
        _s0.marketShareTarget = marketShareTarget;
        _s0.currentMarketShare = FHE.asEuint64(0);
        _s0.annualClaimsEstimate = annualClaims;
        _s0.contractStart = block.timestamp;
        _s0.contractEnd = contractEnd;
        _s0.active = true;

        FHE.allowThis(listPrice); FHE.allow(listPrice, manufacturer);
        FHE.allowThis(netPrice); FHE.allow(netPrice, manufacturer);
        FHE.allowThis(rebateBps); FHE.allow(rebateBps, manufacturer);
        FHE.allowThis(perfThreshold); FHE.allow(perfThreshold, manufacturer);
        FHE.allowThis(marketShareTarget); FHE.allow(marketShareTarget, manufacturer);
        FHE.allowThis(annualClaims); FHE.allow(annualClaims, manufacturer);
        FHE.allowThis(drugContracts[contractId].currentMarketShare);

        _totalRebatesNegotiated = FHE.add(_totalRebatesNegotiated, FHE.div(FHE.mul(annualClaims, rebateBps), 10000));
        FHE.allowThis(_totalRebatesNegotiated);

        emit DrugContractCreated(contractId, manufacturer);
    }

    function recordQuarterlyAccrual(
        bytes32 contractId,
        externalEuint64 encClaimsVolume, bytes calldata cvProof,
        externalEuint64 encCurrentMarketShare, bytes calldata cmsProof,
        uint256 periodStart,
        uint256 periodEnd
    ) external onlyOwner returns (bytes32 accrualId) {
        DrugContract storage dc = drugContracts[contractId];
        require(dc.active, "Contract not active");

        euint64 claimsVolume = FHE.fromExternal(encClaimsVolume, cvProof);
        euint64 currentMarketShare = FHE.fromExternal(encCurrentMarketShare, cmsProof);
        dc.currentMarketShare = currentMarketShare;

        euint64 grossRebate = FHE.div(FHE.mul(FHE.mul(claimsVolume, dc.listPrice), dc.guaranteedRebateBps), 10000);

        // Performance bonus if market share >= target
        ebool performanceMet = FHE.ge(currentMarketShare, dc.marketShareTarget);
        euint64 perfBonus = FHE.select(performanceMet,
            FHE.div(FHE.mul(grossRebate, 500), 10000), // extra 5%
            FHE.asEuint64(0));

        euint64 netRebate = FHE.add(grossRebate, perfBonus);

        accrualId = keccak256(abi.encodePacked(contractId, periodStart, periodEnd));
        accruals[accrualId].drugContractId = contractId;
        accruals[accrualId].claimsVolume = claimsVolume;
        accruals[accrualId].grossRebateAccrued = grossRebate;
        accruals[accrualId].performanceBonusAccrued = perfBonus;
        accruals[accrualId].marketShareAdjustment = FHE.asEuint64(0);
        accruals[accrualId].netRebateDue = netRebate;
        accruals[accrualId].status = SettlementStatus.PENDING;
        accruals[accrualId].periodStart = periodStart;
        accruals[accrualId].periodEnd = periodEnd;

        _formularyRebatePool = FHE.add(_formularyRebatePool, netRebate);

        FHE.allowThis(claimsVolume); FHE.allow(claimsVolume, dc.manufacturer);
        FHE.allowThis(grossRebate); FHE.allow(grossRebate, dc.manufacturer);
        FHE.allowThis(perfBonus); FHE.allow(perfBonus, dc.manufacturer);
        FHE.allowThis(netRebate); FHE.allow(netRebate, dc.manufacturer);
        FHE.allowThis(currentMarketShare); FHE.allow(currentMarketShare, dc.manufacturer);
        FHE.allowThis(accruals[accrualId].marketShareAdjustment);
        FHE.allowThis(_formularyRebatePool);

        if (FHE.isInitialized(perfBonus)) {
            emit PerformanceBonusTriggered(contractId);
        }
        emit RebateAccrualRecorded(accrualId, contractId);
    }

    function settleRebate(bytes32 accrualId, address planSponsor) external onlyOwner {
        RebateAccrual storage accrual = accruals[accrualId];
        require(accrual.status == SettlementStatus.AUDITED, "Not audited");
        require(authorizedPlanSponsor[planSponsor], "Not authorized plan sponsor");

        PlanSponsorAccount storage plan = planSponsors[planSponsor];
        euint64 pbmFee = FHE.div(FHE.mul(accrual.netRebateDue, 1000), 10000); // 10% PBM admin fee
        euint64 passThrough = FHE.sub(accrual.netRebateDue, pbmFee);

        if (plan.transparencyModel) {
            plan.passThroughAmount = FHE.add(plan.passThroughAmount, passThrough);
            plan.pbmRetainedFees = FHE.add(plan.pbmRetainedFees, pbmFee);
            FHE.allowThis(plan.passThroughAmount);
            FHE.allow(plan.passThroughAmount, planSponsor); // [acl_misconfig]
            FHE.allow(_totalRebatesNegotiated, msg.sender); // [acl_misconfig]
            FHE.allow(_totalPBMFees, msg.sender); // [acl_misconfig]
        }

        plan.totalRebatesEarned = FHE.add(plan.totalRebatesEarned, accrual.netRebateDue);
        plan.totalRebatesReceived = FHE.add(plan.totalRebatesReceived, passThrough);
        _totalPBMFees = FHE.add(_totalPBMFees, pbmFee);

        accrual.status = SettlementStatus.SETTLED;

        FHE.allowThis(plan.totalRebatesEarned);
        FHE.allow(plan.totalRebatesEarned, planSponsor);
        FHE.allowThis(plan.totalRebatesReceived);
        FHE.allow(plan.totalRebatesReceived, planSponsor);
        FHE.allowThis(plan.pbmRetainedFees);
        FHE.allowThis(_totalPBMFees);
        FHE.allowTransient(passThrough, planSponsor);

        emit RebateSettled(accrualId, planSponsor);
    }

    function authorizeParticipant(address participant, bool isManufacturer) external onlyOwner {
        if (isManufacturer) authorizedManufacturer[participant] = true;
        else authorizedPlanSponsor[participant] = true;
    }

    function allowPBMStatsView(address viewer) external onlyOwner {
        FHE.allow(_totalRebatesNegotiated, viewer);
        FHE.allow(_totalPBMFees, viewer);
        FHE.allow(_formularyRebatePool, viewer);
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