// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateVentureCapitalFund - Encrypted LP capital call management and portfolio distribution
contract PrivateVentureCapitalFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LimitedPartner {
        euint64 committedCapital;
        euint64 calledCapital;
        euint64 distributionsReceived;
        euint8  carryRate;        // encrypted carry % owed
        bool    active;
        uint256 admittedAt;
    }

    struct CapitalCall {
        euint64 totalCallAmount;
        euint64 collectedAmount;
        uint256 deadline;
        bool    finalized;
        string  purpose;
    }

    struct PortfolioCompany {
        string  name;
        euint64 investedAmount;
        euint64 currentValuation;
        euint8  ownershipPercent;  // encrypted % stake
        bool    exited;
    }

    mapping(address => LimitedPartner) public lps;
    mapping(uint256 => CapitalCall)    public capitalCalls;
    mapping(uint256 => mapping(address => euint64)) private lpCallAmounts;
    mapping(uint256 => PortfolioCompany) public portfolio;
    address[] public lpList;
    uint256 public callCount;
    uint256 public portfolioCount;
    euint64 private totalFundAUM;
    euint64 private totalDistributed;

    event LPAdmitted(address indexed lp);
    event CapitalCallIssued(uint256 indexed callId, string purpose);
    event CapitalCallPaid(uint256 indexed callId, address indexed lp);
    event InvestmentMade(uint256 indexed companyId, string name);
    event DistributionIssued(address indexed lp);

    constructor() Ownable(msg.sender) {
        totalFundAUM    = FHE.asEuint64(0);
        totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(totalFundAUM);
        FHE.allowThis(totalDistributed);
    }

    function admitLP(
        address lp,
        externalEuint64 encCommitment, bytes calldata commitProof,
        externalEuint8 encCarry,      bytes calldata carryProof
    ) external onlyOwner {
        require(!lps[lp].active, "Already admitted");
        LimitedPartner storage l = lps[lp];
        l.committedCapital      = FHE.fromExternal(encCommitment, commitProof);
        l.carryRate             = FHE.fromExternal(encCarry,      carryProof);
        l.calledCapital         = FHE.asEuint64(0);
        l.distributionsReceived = FHE.asEuint64(0);
        l.active                = true;
        l.admittedAt            = block.timestamp;
        FHE.allowThis(l.committedCapital); FHE.allowThis(l.carryRate);
        FHE.allowThis(l.calledCapital); FHE.allowThis(l.distributionsReceived);
        FHE.allow(l.committedCapital, lp);
        FHE.allow(l.distributionsReceived, lp);
        lpList.push(lp);
        emit LPAdmitted(lp);
    }

    function issueCapitalCall(
        string calldata purpose,
        uint256 deadlineDays,
        externalEuint64 encTotal, bytes calldata inputProof
    ) external onlyOwner returns (uint256 callId) {
        callId = callCount++;
        CapitalCall storage c = capitalCalls[callId];
        c.purpose        = purpose;
        c.totalCallAmount = FHE.fromExternal(encTotal, inputProof);
        c.collectedAmount = FHE.asEuint64(0);
        c.deadline        = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(c.totalCallAmount); FHE.allowThis(c.collectedAmount);
        FHE.allow(c.totalCallAmount, owner());
        emit CapitalCallIssued(callId, purpose);
    }

    function payCapitalCall(
        uint256 callId,
        externalEuint64 encAmount, bytes calldata inputProof
    ) external nonReentrant {
        require(lps[msg.sender].active, "Not LP");
        CapitalCall storage c = capitalCalls[callId];
        require(block.timestamp <= c.deadline && !c.finalized, "Closed");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        lpCallAmounts[callId][msg.sender] = FHE.add(lpCallAmounts[callId][msg.sender], amount);
        c.collectedAmount = FHE.add(c.collectedAmount, amount);
        lps[msg.sender].calledCapital = FHE.add(lps[msg.sender].calledCapital, amount);
        totalFundAUM = FHE.add(totalFundAUM, amount);
        FHE.allowThis(lpCallAmounts[callId][msg.sender]);
        FHE.allowThis(c.collectedAmount); FHE.allowThis(lps[msg.sender].calledCapital); FHE.allowThis(totalFundAUM);
        FHE.allow(lpCallAmounts[callId][msg.sender], msg.sender);
        emit CapitalCallPaid(callId, msg.sender);
    }

    function makeInvestment(
        string calldata name,
        externalEuint64 encAmount,    bytes calldata amountProof,
        externalEuint64 encValuation, bytes calldata valuationProof,
        externalEuint8 encOwnership, bytes calldata ownershipProof
    ) external onlyOwner returns (uint256 companyId) {
        companyId = portfolioCount++;
        PortfolioCompany storage co = portfolio[companyId];
        co.name             = name;
        co.investedAmount   = FHE.fromExternal(encAmount,    amountProof);
        co.currentValuation = FHE.fromExternal(encValuation, valuationProof);
        co.ownershipPercent = FHE.fromExternal(encOwnership, ownershipProof);
        FHE.allowThis(co.investedAmount); FHE.allowThis(co.currentValuation); FHE.allowThis(co.ownershipPercent);
        FHE.allow(co.investedAmount, owner());
        emit InvestmentMade(companyId, name);
    }

    function distributeToLP(
        address lp,
        externalEuint64 encAmount, bytes calldata inputProof
    ) external onlyOwner nonReentrant {
        require(lps[lp].active, "Not LP");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        lps[lp].distributionsReceived = FHE.add(lps[lp].distributionsReceived, amount);
        totalDistributed = FHE.add(totalDistributed, amount);
        FHE.allowThis(lps[lp].distributionsReceived); FHE.allowThis(totalDistributed);
        FHE.allow(lps[lp].distributionsReceived, lp);
        FHE.allowTransient(amount, lp);
        emit DistributionIssued(lp);
    }
}
