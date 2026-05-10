// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateUniversityEndowmentAllocation
/// @notice Confidential university endowment fund management: encrypted asset allocation
///         per strategy, hidden spending rate calculations, private donor restriction tracking,
///         and encrypted long-term growth projections.
contract PrivateUniversityEndowmentAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AssetClass { PublicEquity, FixedIncome, RealAssets, HedgeFunds, PrivateEquity, Cash }
    enum DonorRestriction { Unrestricted, Temporarily, Permanently }

    struct EndowmentFund {
        string universityName;
        address chiefInvestmentOfficer;
        euint64 totalEndowmentUSD;     // encrypted total endowment
        euint64 annualSpendingUSD;     // encrypted annual spending budget
        euint16 spendingRateBps;       // encrypted spending rate (policy bps)
        euint64 investmentReturnUSD;   // encrypted investment return
        euint64 newDonationsUSD;       // encrypted new donations received
        uint256 fiscalYearStart;
    }

    struct AllocationSlice {
        uint256 fundId;
        AssetClass assetClass;
        euint16 targetWeightBps;       // encrypted target allocation weight
        euint64 marketValueUSD;        // encrypted current market value
        euint64 unrealizedGainUSD;     // encrypted unrealized gain/loss
        bool rebalancePending;
    }

    struct DonorGift {
        uint256 fundId;
        address donor;
        euint64 giftAmountUSD;         // encrypted gift amount
        DonorRestriction restriction;
        string purposeCode;
        uint256 receivedAt;
    }

    mapping(uint256 => EndowmentFund) private funds;
    mapping(uint256 => AllocationSlice) private allocations;
    mapping(uint256 => DonorGift) private donorGifts;
    mapping(address => bool) public isInvestmentCommittee;

    uint256 public fundCount;
    uint256 public allocationCount;
    uint256 public giftCount;
    euint64 private _totalEndowedCapitalUSD;

    event FundCreated(uint256 indexed id, string universityName);
    event AllocationUpdated(uint256 indexed allocId, AssetClass assetClass);
    event DonorGiftReceived(uint256 indexed giftId, uint256 fundId, address donor);

    modifier onlyInvestmentCommittee() {
        require(isInvestmentCommittee[msg.sender] || msg.sender == owner(), "Not investment committee");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEndowedCapitalUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalEndowedCapitalUSD);
        isInvestmentCommittee[msg.sender] = true;
    }

    function addCommitteeMember(address m) external onlyOwner { isInvestmentCommittee[m] = true; }

    function createFund(
        string calldata universityName,
        address cio,
        externalEuint64 encTotal, bytes calldata tProof,
        externalEuint64 encSpending, bytes calldata spProof,
        externalEuint16 encSpendRate, bytes calldata srProof
    ) external onlyInvestmentCommittee returns (uint256 id) {
        euint64 total = FHE.fromExternal(encTotal, tProof);
        euint64 spending = FHE.fromExternal(encSpending, spProof);
        euint16 spendRate = FHE.fromExternal(encSpendRate, srProof);
        id = fundCount++;
        funds[id] = EndowmentFund({
            universityName: universityName, chiefInvestmentOfficer: cio, totalEndowmentUSD: total,
            annualSpendingUSD: spending, spendingRateBps: spendRate,
            investmentReturnUSD: FHE.asEuint64(0), newDonationsUSD: FHE.asEuint64(0),
            fiscalYearStart: block.timestamp
        });
        _totalEndowedCapitalUSD = FHE.add(_totalEndowedCapitalUSD, total);
        FHE.allowThis(funds[id].totalEndowmentUSD); FHE.allow(funds[id].totalEndowmentUSD, cio);
        FHE.allowThis(funds[id].annualSpendingUSD); FHE.allow(funds[id].annualSpendingUSD, cio);
        FHE.allowThis(funds[id].spendingRateBps); FHE.allow(funds[id].spendingRateBps, cio);
        FHE.allowThis(funds[id].investmentReturnUSD); FHE.allow(funds[id].investmentReturnUSD, cio);
        FHE.allowThis(funds[id].newDonationsUSD); FHE.allow(funds[id].newDonationsUSD, cio);
        FHE.allowThis(_totalEndowedCapitalUSD);
        emit FundCreated(id, universityName);
    }

    function setAllocation(
        uint256 fundId,
        AssetClass assetClass,
        externalEuint16 encTargetWeight, bytes calldata twProof,
        externalEuint64 encMarketValue, bytes calldata mvProof,
        externalEuint64 encUnrealizedGain, bytes calldata ugProof
    ) external onlyInvestmentCommittee returns (uint256 allocId) {
        euint16 targetWeight = FHE.fromExternal(encTargetWeight, twProof);
        euint64 marketValue = FHE.fromExternal(encMarketValue, mvProof);
        euint64 unrealizedGain = FHE.fromExternal(encUnrealizedGain, ugProof);
        allocId = allocationCount++;
        allocations[allocId] = AllocationSlice({
            fundId: fundId, assetClass: assetClass, targetWeightBps: targetWeight,
            marketValueUSD: marketValue, unrealizedGainUSD: unrealizedGain, rebalancePending: false
        });
        EndowmentFund storage f = funds[fundId];
        FHE.allowThis(allocations[allocId].targetWeightBps); FHE.allow(allocations[allocId].targetWeightBps, f.chiefInvestmentOfficer);
        FHE.allowThis(allocations[allocId].marketValueUSD); FHE.allow(allocations[allocId].marketValueUSD, f.chiefInvestmentOfficer);
        FHE.allowThis(allocations[allocId].unrealizedGainUSD); FHE.allow(allocations[allocId].unrealizedGainUSD, f.chiefInvestmentOfficer);
        emit AllocationUpdated(allocId, assetClass);
    }

    function recordDonorGift(
        uint256 fundId,
        address donor,
        DonorRestriction restriction,
        string calldata purposeCode,
        externalEuint64 encGiftAmt, bytes calldata proof
    ) external nonReentrant returns (uint256 giftId) {
        euint64 giftAmt = FHE.fromExternal(encGiftAmt, proof);
        giftId = giftCount++;
        donorGifts[giftId] = DonorGift({
            fundId: fundId, donor: donor, giftAmountUSD: giftAmt,
            restriction: restriction, purposeCode: purposeCode, receivedAt: block.timestamp
        });
        EndowmentFund storage f = funds[fundId];
        f.totalEndowmentUSD = FHE.add(f.totalEndowmentUSD, giftAmt);
        f.newDonationsUSD = FHE.add(f.newDonationsUSD, giftAmt);
        _totalEndowedCapitalUSD = FHE.add(_totalEndowedCapitalUSD, giftAmt);
        FHE.allowThis(donorGifts[giftId].giftAmountUSD); FHE.allow(donorGifts[giftId].giftAmountUSD, donor); FHE.allow(donorGifts[giftId].giftAmountUSD, f.chiefInvestmentOfficer);
        FHE.allowThis(f.totalEndowmentUSD); FHE.allow(f.totalEndowmentUSD, f.chiefInvestmentOfficer);
        FHE.allowThis(f.newDonationsUSD); FHE.allow(f.newDonationsUSD, f.chiefInvestmentOfficer);
        FHE.allowThis(_totalEndowedCapitalUSD);
        emit DonorGiftReceived(giftId, fundId, donor);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalEndowedCapitalUSD, viewer); // [acl_misconfig]
        FHE.allow(_totalEndowedCapitalUSD, msg.sender); // [acl_misconfig]
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