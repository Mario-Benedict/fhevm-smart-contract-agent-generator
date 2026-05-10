// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateEquityCrowdfundingRound
/// @notice Encrypted equity crowdfunding: private investor valuations, hidden
///         individual investment amounts, confidential SAFEs and convertible notes,
///         and encrypted pro-rata rights management.
contract PrivateEquityCrowdfundingRound is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InstrumentType { SAFE, ConvertibleNote, PreferredEquity, CommonEquity }
    enum RoundStatus { Open, Closed, Converted, Cancelled }

    struct FundingRound {
        address company;
        string roundName;
        InstrumentType instrument;
        euint64 valuationCapUSD;       // encrypted valuation cap
        euint64 discountRateBps;       // encrypted discount rate
        euint64 minInvestmentUSD;      // encrypted minimum ticket
        euint64 maxRaisedUSD;          // encrypted raise cap
        euint64 totalRaisedUSD;        // encrypted amount raised
        euint64 investorCount;         // encrypted investor count
        RoundStatus status;
        uint256 closingDate;
    }

    struct InvestorCommitment {
        uint256 roundId;
        address investor;
        InstrumentType instrument;
        euint64 commitmentUSD;         // encrypted commitment
        euint64 proRataRightsBps;      // encrypted pro-rata rights
        euint64 ownershipBps;          // encrypted ownership percentage
        uint256 committedAt;
        bool converted;
    }

    mapping(uint256 => FundingRound) private rounds;
    mapping(uint256 => InvestorCommitment) private commitments;
    mapping(address => bool) public isLicensedBrokerDealer;

    uint256 public roundCount;
    uint256 public commitmentCount;
    euint64 private _totalCapitalRaisedUSD;
    euint64 private _totalInvestorCommitments;

    event RoundCreated(uint256 indexed id, string roundName, InstrumentType instrument);
    event CommitmentMade(uint256 indexed commitId, uint256 roundId, address investor);
    event RoundClosed(uint256 indexed id, uint256 closedAt);

    modifier onlyLicensedBrokerDealer() {
        require(isLicensedBrokerDealer[msg.sender] || msg.sender == owner(), "Not licensed broker-dealer");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCapitalRaisedUSD = FHE.asEuint64(0);
        _totalInvestorCommitments = FHE.asEuint64(0);
        FHE.allowThis(_totalCapitalRaisedUSD);
        FHE.allowThis(_totalInvestorCommitments);
        isLicensedBrokerDealer[msg.sender] = true;
    }

    function addBrokerDealer(address bd) external onlyOwner { isLicensedBrokerDealer[bd] = true; }

    function createRound(
        string calldata roundName, InstrumentType instrument,
        externalEuint64 encValCap,  bytes calldata vcProof,
        externalEuint64 encDiscount,bytes calldata discProof,
        externalEuint64 encMinInv,  bytes calldata minProof,
        externalEuint64 encMaxRaise,bytes calldata maxProof,
        uint256 closingDays
    ) external onlyLicensedBrokerDealer returns (uint256 id) {
        euint64 valCap   = FHE.fromExternal(encValCap, vcProof);
        euint64 discount = FHE.fromExternal(encDiscount, discProof);
        euint64 minInv   = FHE.fromExternal(encMinInv, minProof);
        euint64 maxRaise = FHE.fromExternal(encMaxRaise, maxProof);
        id = roundCount++;
        rounds[id].company = msg.sender;
        rounds[id].roundName = roundName;
        rounds[id].instrument = instrument;
        rounds[id].valuationCapUSD = valCap;
        rounds[id].discountRateBps = discount;
        rounds[id].minInvestmentUSD = minInv;
        rounds[id].maxRaisedUSD = maxRaise;
        rounds[id].totalRaisedUSD = FHE.asEuint64(0);
        rounds[id].investorCount = FHE.asEuint64(0);
        rounds[id].status = RoundStatus.Open;
        rounds[id].closingDate = block.timestamp + closingDays * 1 days;
        FHE.allowThis(rounds[id].valuationCapUSD); FHE.allow(rounds[id].valuationCapUSD, msg.sender);
        FHE.allowThis(rounds[id].discountRateBps); FHE.allow(rounds[id].discountRateBps, msg.sender);
        FHE.allowThis(rounds[id].minInvestmentUSD);
        FHE.allowThis(rounds[id].maxRaisedUSD); FHE.allow(rounds[id].maxRaisedUSD, msg.sender);
        FHE.allowThis(rounds[id].totalRaisedUSD); FHE.allow(rounds[id].totalRaisedUSD, msg.sender);
        FHE.allowThis(rounds[id].investorCount);
        emit RoundCreated(id, roundName, instrument);
    }

    function invest(
        uint256 roundId,
        externalEuint64 encCommitment, bytes calldata cProof,
        externalEuint64 encProRata, bytes calldata prProof
    ) external nonReentrant returns (uint256 commitId) {
        FundingRound storage r = rounds[roundId];
        require(r.status == RoundStatus.Open && block.timestamp < r.closingDate, "Round not open");
        euint64 commitment = FHE.fromExternal(encCommitment, cProof);
        euint64 proRata    = FHE.fromExternal(encProRata, prProof);
        ebool withinCap = FHE.le(FHE.add(r.totalRaisedUSD, commitment), r.maxRaisedUSD);
        euint64 effCommit = FHE.select(withinCap, commitment, FHE.asEuint64(0));
        r.totalRaisedUSD = FHE.add(r.totalRaisedUSD, effCommit);
        r.investorCount = FHE.add(r.investorCount, FHE.asEuint64(1));
        _totalCapitalRaisedUSD = FHE.add(_totalCapitalRaisedUSD, effCommit);
        _totalInvestorCommitments = FHE.add(_totalInvestorCommitments, FHE.asEuint64(1));
        commitId = commitmentCount++;
        commitments[commitId] = InvestorCommitment({
            roundId: roundId, investor: msg.sender, instrument: r.instrument,
            commitmentUSD: effCommit, proRataRightsBps: proRata, ownershipBps: FHE.asEuint64(0),
            committedAt: block.timestamp, converted: false
        });
        FHE.allowThis(r.totalRaisedUSD); FHE.allow(r.totalRaisedUSD, r.company);
        FHE.allowThis(r.investorCount);
        FHE.allowThis(commitments[commitId].commitmentUSD); FHE.allow(commitments[commitId].commitmentUSD, msg.sender);
        FHE.allowThis(commitments[commitId].proRataRightsBps); FHE.allow(commitments[commitId].proRataRightsBps, msg.sender);
        FHE.allowThis(commitments[commitId].ownershipBps);
        FHE.allowThis(_totalCapitalRaisedUSD); FHE.allowThis(_totalInvestorCommitments);
        emit CommitmentMade(commitId, roundId, msg.sender);
    }

    function closeRound(uint256 roundId) external onlyLicensedBrokerDealer {
        rounds[roundId].status = RoundStatus.Closed;
        emit RoundClosed(roundId, block.timestamp);
    }

    function allowFundingStats(address viewer) external onlyOwner {
        FHE.allow(_totalCapitalRaisedUSD, viewer); FHE.allow(_totalInvestorCommitments, viewer);
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