// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateEquineRacehorseSyndicateBid
/// @notice Encrypted racehorse syndicate ownership with confidential purchase
///         prices, prize money distributions, training cost allocations,
///         vet bill sharing, and breeding rights valuations.
contract PrivateEquineRacehorseSyndicateBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum HorseGrade { MAIDEN, CLAIMING, ALLOWANCE, STAKES, GRADED_STAKES, GROUP_ONE }
    enum SyndicateStatus { FORMATION, ACTIVE, RACING, BREEDING, RETIRED, DISSOLVED }
    enum CostCategory { TRAINING, VETERINARY, FARRIER, FEED, TRANSPORT, NOMINATION_FEE, INSURANCE }

    struct HorseSyndicate {
        string horseNameHash;            // hash of horse name
        HorseGrade grade;
        SyndicateStatus status;
        euint64 purchasePriceUSD;        // encrypted purchase price
        euint64 totalSharesIssued;       // encrypted total syndicate shares
        euint64 shareValueUSD;           // encrypted value per share
        euint64 totalPrizeMoney;         // encrypted cumulative prize money
        euint64 totalExpenses;           // encrypted cumulative training expenses
        euint64 netProfitLoss;           // encrypted net P&L
        euint64 breedingRightsValue;     // encrypted stallion/broodmare value
        euint64 insurancePolicyValue;    // encrypted mortality insurance
        euint64 reserveFund;             // encrypted expense reserve
        uint256 acquisitionDate;
        uint256 retirementDate;
        bool breedingRights;
        bool sold;
    }

    struct SyndicateMember {
        euint64 sharesOwned;             // encrypted share count
        euint64 totalCapitalContributed; // encrypted total capital in
        euint64 prizeMoneyClaimed;       // encrypted prize money received
        euint64 expensesPaid;            // encrypted expense contributions
        euint64 currentEquityValue;      // encrypted current equity value
        euint64 unrealizedGainLoss;      // encrypted unrealized P&L
        uint256 joinedAt;
        bool active;
    }

    struct RaceResult {
        bytes32 syndicateId;
        euint64 prizeAmount;             // encrypted prize money won
        euint64 jockeyFee;               // encrypted jockey percentage
        euint64 trainerPercentage;       // encrypted trainer percentage
        euint64 netToSyndicate;          // encrypted net after fees
        uint256 raceDate;
        uint8 finishPosition;
    }

    mapping(bytes32 => HorseSyndicate) private syndicates;
    mapping(bytes32 => mapping(address => SyndicateMember)) private members;
    mapping(bytes32 => RaceResult[]) private raceHistory;
    mapping(bytes32 => address[]) private syndicateMembers;

    euint64 private _totalPrizesAcrossAllSyndicates;  // encrypted total prize pool
    euint64 private _totalAssetsUnderManagement;       // encrypted total AUM

    event SyndicateFormed(bytes32 indexed syndicateId, HorseGrade grade);
    event MemberJoined(bytes32 indexed syndicateId, address indexed member);
    event RaceResultRecorded(bytes32 indexed syndicateId, uint256 raceDate, uint8 position);
    event PrizeMoneySplitDistributed(bytes32 indexed syndicateId);
    event ExpenseCallIssued(bytes32 indexed syndicateId, CostCategory category);
    event SyndicateRetired(bytes32 indexed syndicateId);
    event HorseSold(bytes32 indexed syndicateId);

    constructor() Ownable(msg.sender) {
        _totalPrizesAcrossAllSyndicates = FHE.asEuint64(0);
        _totalAssetsUnderManagement = FHE.asEuint64(0);
        FHE.allowThis(_totalPrizesAcrossAllSyndicates);
        FHE.allowThis(_totalAssetsUnderManagement);
    }

    function formSyndicate(
        string calldata horseNameHash,
        HorseGrade grade,
        externalEuint64 encPurchasePrice, bytes calldata ppProof,
        externalEuint64 encTotalShares, bytes calldata tsProof,
        externalEuint64 encBreedingRightsValue, bytes calldata brvProof,
        externalEuint64 encInsuranceValue, bytes calldata ivProof,
        bool breedingRights,
        uint64 totalSharesPlaintext
    ) external onlyOwner returns (bytes32 syndicateId) {
        euint64 purchasePrice = FHE.fromExternal(encPurchasePrice, ppProof);
        euint64 totalShares = FHE.fromExternal(encTotalShares, tsProof);
        euint64 breedingRightsValue = FHE.fromExternal(encBreedingRightsValue, brvProof);
        euint64 insuranceValue = FHE.fromExternal(encInsuranceValue, ivProof);
        euint64 shareValue = totalSharesPlaintext > 0 ? FHE.div(purchasePrice, totalSharesPlaintext) : FHE.asEuint64(0);

        syndicateId = keccak256(abi.encodePacked(horseNameHash, block.timestamp));

        HorseSyndicate storage _s0 = syndicates[syndicateId];
        _s0.horseNameHash = horseNameHash;
        _s0.grade = grade;
        _s0.status = SyndicateStatus.FORMATION;
        _s0.purchasePriceUSD = purchasePrice;
        _s0.totalSharesIssued = totalShares;
        _s0.shareValueUSD = shareValue;
        _s0.totalPrizeMoney = FHE.asEuint64(0);
        _s0.totalExpenses = FHE.asEuint64(0);
        _s0.netProfitLoss = FHE.asEuint64(0);
        _s0.breedingRightsValue = breedingRightsValue;
        _s0.insurancePolicyValue = insuranceValue;
        _s0.reserveFund = FHE.asEuint64(0);
        _s0.acquisitionDate = block.timestamp;
        _s0.retirementDate = 0;
        _s0.breedingRights = breedingRights;
        _s0.sold = false;

        _totalAssetsUnderManagement = FHE.add(_totalAssetsUnderManagement, purchasePrice);

        FHE.allowThis(purchasePrice); FHE.allowThis(totalShares); FHE.allowThis(shareValue);
        FHE.allowThis(breedingRightsValue); FHE.allowThis(insuranceValue);
        FHE.allowThis(syndicates[syndicateId].totalPrizeMoney);
        FHE.allowThis(syndicates[syndicateId].totalExpenses);
        FHE.allowThis(syndicates[syndicateId].netProfitLoss);
        FHE.allowThis(syndicates[syndicateId].reserveFund);
        FHE.allowThis(_totalAssetsUnderManagement);

        emit SyndicateFormed(syndicateId, grade);
    }

    function joinSyndicate(
        bytes32 syndicateId,
        externalEuint64 encSharesWanted, bytes calldata swProof
    ) external nonReentrant {
        HorseSyndicate storage syn = syndicates[syndicateId];
        require(syn.status == SyndicateStatus.FORMATION, "Not in formation");

        euint64 sharesWanted = FHE.fromExternal(encSharesWanted, swProof);
        euint64 capitalRequired = FHE.mul(sharesWanted, syn.shareValueUSD);

        members[syndicateId][msg.sender] = SyndicateMember({
            sharesOwned: sharesWanted,
            totalCapitalContributed: capitalRequired,
            prizeMoneyClaimed: FHE.asEuint64(0),
            expensesPaid: FHE.asEuint64(0),
            currentEquityValue: capitalRequired,
            unrealizedGainLoss: FHE.asEuint64(0),
            joinedAt: block.timestamp,
            active: true
        });
        syndicateMembers[syndicateId].push(msg.sender);

        FHE.allowThis(sharesWanted); FHE.allow(sharesWanted, msg.sender);
        FHE.allowThis(capitalRequired); FHE.allow(capitalRequired, msg.sender);
        FHE.allowThis(members[syndicateId][msg.sender].prizeMoneyClaimed);
        FHE.allow(members[syndicateId][msg.sender].prizeMoneyClaimed, msg.sender);
        FHE.allowThis(members[syndicateId][msg.sender].expensesPaid);
        FHE.allow(members[syndicateId][msg.sender].expensesPaid, msg.sender);
        FHE.allowThis(members[syndicateId][msg.sender].currentEquityValue);
        FHE.allow(members[syndicateId][msg.sender].currentEquityValue, msg.sender);
        FHE.allowThis(members[syndicateId][msg.sender].unrealizedGainLoss);
        FHE.allow(members[syndicateId][msg.sender].unrealizedGainLoss, msg.sender);

        emit MemberJoined(syndicateId, msg.sender);
    }

    function recordRaceResult(
        bytes32 syndicateId,
        uint8 finishPosition,
        externalEuint64 encPrizeAmount, bytes calldata paProof,
        externalEuint64 encJockeyFee, bytes calldata jfProof,
        externalEuint64 encTrainerPct, bytes calldata tpProof,
        uint256 raceDate
    ) external onlyOwner {
        euint64 prizeAmount = FHE.fromExternal(encPrizeAmount, paProof);
        euint64 jockeyFee = FHE.fromExternal(encJockeyFee, jfProof);
        euint64 trainerPct = FHE.fromExternal(encTrainerPct, tpProof);
        euint64 netToSyndicate = FHE.sub(prizeAmount, FHE.add(jockeyFee, trainerPct));

        raceHistory[syndicateId].push(RaceResult({
            syndicateId: syndicateId,
            prizeAmount: prizeAmount,
            jockeyFee: jockeyFee,
            trainerPercentage: trainerPct,
            netToSyndicate: netToSyndicate,
            raceDate: raceDate,
            finishPosition: finishPosition
        }));

        syndicates[syndicateId].totalPrizeMoney = FHE.add(syndicates[syndicateId].totalPrizeMoney, netToSyndicate);
        _totalPrizesAcrossAllSyndicates = FHE.add(_totalPrizesAcrossAllSyndicates, netToSyndicate);

        FHE.allowThis(prizeAmount); FHE.allowThis(jockeyFee); FHE.allowThis(trainerPct);
        FHE.allowThis(netToSyndicate);
        FHE.allowThis(syndicates[syndicateId].totalPrizeMoney);
        FHE.allowThis(_totalPrizesAcrossAllSyndicates);

        emit RaceResultRecorded(syndicateId, raceDate, finishPosition);
    }

    function distributePrizeMoney(bytes32 syndicateId, uint64 totalSharesPlaintext) external onlyOwner {
        HorseSyndicate storage syn = syndicates[syndicateId];
        address[] storage memberList = syndicateMembers[syndicateId];

        for (uint256 i = 0; i < memberList.length; i++) {
            SyndicateMember storage m = members[syndicateId][memberList[i]];
            if (!m.active) continue;
            euint64 memberShare = totalSharesPlaintext > 0
                ? FHE.div(FHE.mul(syn.totalPrizeMoney, m.sharesOwned), totalSharesPlaintext)
                : FHE.asEuint64(0);
            m.prizeMoneyClaimed = FHE.add(m.prizeMoneyClaimed, memberShare);
            m.currentEquityValue = FHE.add(m.currentEquityValue, memberShare);
            FHE.allowThis(m.prizeMoneyClaimed);
            FHE.allow(m.prizeMoneyClaimed, memberList[i]);
            FHE.allowThis(m.currentEquityValue);
            FHE.allow(m.currentEquityValue, memberList[i]);
            FHE.allowTransient(memberShare, memberList[i]);
        }
        syn.totalPrizeMoney = FHE.asEuint64(0);
        FHE.allowThis(syn.totalPrizeMoney);
        emit PrizeMoneySplitDistributed(syndicateId);
    }

    function issueExpenseCall(
        bytes32 syndicateId,
        CostCategory category,
        externalEuint64 encTotalExpense, bytes calldata teProof,
        uint64 totalSharesPlaintext
    ) external onlyOwner {
        HorseSyndicate storage syn = syndicates[syndicateId];
        euint64 totalExpense = FHE.fromExternal(encTotalExpense, teProof);
        syn.totalExpenses = FHE.add(syn.totalExpenses, totalExpense);

        address[] storage memberList = syndicateMembers[syndicateId];
        for (uint256 i = 0; i < memberList.length; i++) {
            SyndicateMember storage m = members[syndicateId][memberList[i]];
            if (!m.active) continue;
            euint64 memberExpenseShare = totalSharesPlaintext > 0
                ? FHE.div(FHE.mul(totalExpense, m.sharesOwned), totalSharesPlaintext)
                : FHE.asEuint64(0);
            m.expensesPaid = FHE.add(m.expensesPaid, memberExpenseShare);
            FHE.allowThis(m.expensesPaid);
            FHE.allow(m.expensesPaid, memberList[i]);
            FHE.allowTransient(memberExpenseShare, memberList[i]);
        }

        FHE.allowThis(syn.totalExpenses);
        emit ExpenseCallIssued(syndicateId, category);
    }

    function allowSyndicateStatsView(bytes32 syndicateId, address viewer) external onlyOwner {
        HorseSyndicate storage syn = syndicates[syndicateId];
        FHE.allow(syn.purchasePriceUSD, viewer);
        FHE.allow(syn.totalPrizeMoney, viewer);
        FHE.allow(syn.totalExpenses, viewer);
        FHE.allow(syn.netProfitLoss, viewer);
        FHE.allow(syn.shareValueUSD, viewer);
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