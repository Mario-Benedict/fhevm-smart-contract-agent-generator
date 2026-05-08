// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDividendReinvestment - Encrypted DRIP plan with private share accumulation
contract PrivateDividendReinvestment is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Participant {
        euint64 sharesOwned;
        euint64 reinvestedTotal;
        euint64 cashDividendsReceived;
        bool    autoReinvest;
        bool    enrolled;
    }

    struct DividendRound {
        euint64 totalDividendPool;
        euint64 sharePrice;         // price used for reinvestment
        euint64 totalSharesReinvested;
        uint256 exDate;
        uint256 payDate;
        bool    processed;
    }

    mapping(address => Participant) public participants;
    mapping(uint256 => DividendRound) public rounds;
    uint256 public roundCount;
    uint256 public totalEnrolled;

    event ParticipantEnrolled(address indexed participant);
    event ReinvestPreferenceUpdated(address indexed participant, bool autoReinvest);
    event DividendRoundCreated(uint256 indexed roundId);
    event DividendProcessed(uint256 indexed roundId, address indexed participant);

    constructor() Ownable(msg.sender) {}

    function enroll(
        externalEuint64 calldata encShares, bytes calldata inputProof,
        bool autoReinvest
    ) external {
        require(!participants[msg.sender].enrolled, "Already enrolled");
        Participant storage p = participants[msg.sender];
        p.sharesOwned           = FHE.fromExternal(encShares, inputProof);
        p.reinvestedTotal       = FHE.asEuint64(0);
        p.cashDividendsReceived = FHE.asEuint64(0);
        p.autoReinvest          = autoReinvest;
        p.enrolled              = true;
        FHE.allowThis(p.sharesOwned); FHE.allowThis(p.reinvestedTotal); FHE.allowThis(p.cashDividendsReceived);
        FHE.allow(p.sharesOwned, msg.sender);
        totalEnrolled++;
        emit ParticipantEnrolled(msg.sender);
    }

    function setAutoReinvest(bool autoReinvest) external {
        require(participants[msg.sender].enrolled, "Not enrolled");
        participants[msg.sender].autoReinvest = autoReinvest;
        emit ReinvestPreferenceUpdated(msg.sender, autoReinvest);
    }

    function createDividendRound(
        uint256 exDateDays, uint256 payDateDays,
        externalEuint64 calldata encPool,  bytes calldata poolProof,
        externalEuint64 calldata encPrice, bytes calldata priceProof
    ) external onlyOwner returns (uint256 roundId) {
        roundId = roundCount++;
        DividendRound storage r = rounds[roundId];
        r.totalDividendPool     = FHE.fromExternal(encPool,  poolProof);
        r.sharePrice            = FHE.fromExternal(encPrice, priceProof);
        r.totalSharesReinvested = FHE.asEuint64(0);
        r.exDate  = block.timestamp + exDateDays  * 1 days;
        r.payDate = block.timestamp + payDateDays * 1 days;
        FHE.allowThis(r.totalDividendPool); FHE.allowThis(r.sharePrice); FHE.allowThis(r.totalSharesReinvested);
        emit DividendRoundCreated(roundId);
    }

    function processDividend(uint256 roundId, address participant) external onlyOwner nonReentrant {
        DividendRound storage r = rounds[roundId];
        require(block.timestamp >= r.payDate, "Not pay date");
        Participant storage p = participants[participant];
        require(p.enrolled, "Not enrolled");

        euint64 perShareDiv = FHE.div(r.totalDividendPool, FHE.asEuint64(uint64(totalEnrolled)));
        euint64 grossDiv    = FHE.mul(p.sharesOwned, perShareDiv);

        if (p.autoReinvest) {
            euint64 newShares = FHE.div(grossDiv, r.sharePrice);
            p.sharesOwned       = FHE.add(p.sharesOwned, newShares);
            p.reinvestedTotal   = FHE.add(p.reinvestedTotal, grossDiv);
            r.totalSharesReinvested = FHE.add(r.totalSharesReinvested, newShares);
            FHE.allowThis(p.sharesOwned); FHE.allowThis(p.reinvestedTotal); FHE.allowThis(r.totalSharesReinvested);
            FHE.allow(p.sharesOwned, participant);
        } else {
            p.cashDividendsReceived = FHE.add(p.cashDividendsReceived, grossDiv);
            FHE.allowThis(p.cashDividendsReceived);
            FHE.allow(p.cashDividendsReceived, participant);
            FHE.allowTransient(grossDiv, participant);
        }
        emit DividendProcessed(roundId, participant);
    }
}
