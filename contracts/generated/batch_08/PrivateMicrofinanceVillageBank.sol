// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMicrofinanceVillageBank
/// @notice Village savings and loan group (VSLA): encrypted member savings, encrypted group loan pools,
///         encrypted repayment schedules, and confidential group creditworthiness scoring.
contract PrivateMicrofinanceVillageBank is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct VillageGroup {
        string groupName;
        string village;
        euint64 groupSavingsPool;     // encrypted total savings pool
        euint64 loanFundUSD;          // encrypted current loan fund
        euint64 groupCreditScore;     // encrypted group credit score 0-1000
        euint64 defaultRateBps;       // encrypted historical default rate
        euint64 interestEarnedUSD;    // encrypted total interest earned
        uint256 memberCount;
        bool active;
    }

    struct MemberAccount {
        uint256 groupId;
        euint64 savingsBalance;        // encrypted savings
        euint64 loanBalance;           // encrypted outstanding loan
        euint64 repaymentScore;        // encrypted repayment history score
        euint64 weeklyContribution;    // encrypted weekly savings amount
        bool hasLoan;
        bool active;
    }

    struct LoanRequest {
        uint256 groupId;
        address member;
        euint64 requestedAmountUSD;   // encrypted requested loan
        euint64 approvedAmountUSD;    // encrypted approved amount
        euint64 weeklyRepaymentUSD;   // encrypted weekly repayment
        euint64 interestRateBps;      // encrypted interest rate
        euint64 repaidSoFarUSD;       // encrypted amount repaid
        uint16 termWeeks;
        uint256 issuedAt;
        bool approved;
        bool repaid;
        bool defaulted;
    }

    mapping(uint256 => VillageGroup) private groups;
    mapping(bytes32 => MemberAccount) private accounts; // keccak(groupId, member)
    mapping(uint256 => LoanRequest) private loans;
    uint256 public groupCount;
    uint256 public loanCount;
    euint64 private _totalNetworkSavings;
    euint64 private _totalNetworkLoans;
    mapping(address => bool) public isMFIAgent;

    event GroupRegistered(uint256 indexed id, string name, string village);
    event MemberJoined(uint256 indexed groupId, address member);
    event SavingsDeposited(uint256 indexed groupId, address member);
    event LoanRequested(uint256 indexed loanId, uint256 groupId, address member);
    event LoanApproved(uint256 indexed loanId);
    event LoanRepaid(uint256 indexed loanId, address member);

    constructor() Ownable(msg.sender) {
        _totalNetworkSavings = FHE.asEuint64(0);
        _totalNetworkLoans = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkSavings);
        FHE.allowThis(_totalNetworkLoans);
        isMFIAgent[msg.sender] = true;
    }

    function addAgent(address a) external onlyOwner { isMFIAgent[a] = true; }

    function registerGroup(string calldata name, string calldata village) external returns (uint256 id) {
        require(isMFIAgent[msg.sender], "Not agent");
        id = groupCount++;
        groups[id].groupName = name;
        groups[id].village = village;
        groups[id].groupSavingsPool = FHE.asEuint64(0);
        groups[id].loanFundUSD = FHE.asEuint64(0);
        groups[id].groupCreditScore = FHE.asEuint64(500);
        groups[id].defaultRateBps = FHE.asEuint64(0);
        groups[id].interestEarnedUSD = FHE.asEuint64(0);
        groups[id].memberCount = 0;
        groups[id].active = true;
        FHE.allowThis(groups[id].groupSavingsPool);
        FHE.allowThis(groups[id].loanFundUSD);
        FHE.allowThis(groups[id].groupCreditScore);
        FHE.allowThis(groups[id].defaultRateBps);
        FHE.allowThis(groups[id].interestEarnedUSD);
        emit GroupRegistered(id, name, village);
    }

    function joinGroup(uint256 groupId, externalEuint64 encWeeklyContribution, bytes calldata proof) external {
        require(groups[groupId].active, "Group inactive");
        euint64 weekly = FHE.fromExternal(encWeeklyContribution, proof);
        bytes32 key = keccak256(abi.encodePacked(groupId, msg.sender));
        accounts[key] = MemberAccount({
            groupId: groupId, savingsBalance: FHE.asEuint64(0),
            loanBalance: FHE.asEuint64(0), repaymentScore: FHE.asEuint64(500),
            weeklyContribution: weekly, hasLoan: false, active: true
        });
        groups[groupId].memberCount++;
        FHE.allowThis(accounts[key].savingsBalance);
        FHE.allowThis(accounts[key].loanBalance);
        FHE.allowThis(accounts[key].repaymentScore);
        FHE.allowThis(accounts[key].weeklyContribution);
        FHE.allow(accounts[key].savingsBalance, msg.sender);
        FHE.allow(accounts[key].repaymentScore, msg.sender);
        emit MemberJoined(groupId, msg.sender);
    }

    function depositSavings(uint256 groupId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        bytes32 key = keccak256(abi.encodePacked(groupId, msg.sender));
        require(accounts[key].active, "Not member");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        accounts[key].savingsBalance = FHE.add(accounts[key].savingsBalance, amount);
        groups[groupId].groupSavingsPool = FHE.add(groups[groupId].groupSavingsPool, amount);
        groups[groupId].loanFundUSD = FHE.add(groups[groupId].loanFundUSD, amount);
        _totalNetworkSavings = FHE.add(_totalNetworkSavings, amount);
        FHE.allowThis(accounts[key].savingsBalance);
        FHE.allow(accounts[key].savingsBalance, msg.sender);
        FHE.allowThis(groups[groupId].groupSavingsPool);
        FHE.allowThis(groups[groupId].loanFundUSD);
        FHE.allowThis(_totalNetworkSavings);
        emit SavingsDeposited(groupId, msg.sender);
    }

    function requestLoan(
        uint256 groupId, uint16 termWeeks,
        externalEuint64 encAmount, bytes calldata proof
    ) external returns (uint256 loanId) {
        bytes32 key = keccak256(abi.encodePacked(groupId, msg.sender));
        MemberAccount storage acc = accounts[key];
        require(acc.active && !acc.hasLoan, "Not eligible");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Max loan = 3x savings balance
        euint64 maxLoan = FHE.mul(acc.savingsBalance, FHE.asEuint64(3));
        ebool withinMax = FHE.le(amount, maxLoan);
        euint64 actual = FHE.select(withinMax, amount, maxLoan);
        // Interest: base 15% + (500-repaymentScore)/500 * 10%
        euint64 interestRate = FHE.asEuint64(1500);
        euint64 weeklyRepayment = (uint64(termWeeks) * uint64(termWeeks)) > 0
            ? FHE.div(FHE.mul(actual, FHE.asEuint64(uint64(termWeeks + 1))), uint64(termWeeks) * uint64(termWeeks))
            : FHE.asEuint64(0);
        loanId = loanCount++;
        LoanRequest storage _s0 = loans[loanId];
        _s0.groupId = groupId;
        _s0.member = msg.sender;
        _s0.requestedAmountUSD = amount;
        _s0.approvedAmountUSD = FHE.asEuint64(0);
        _s0.weeklyRepaymentUSD = weeklyRepayment;
        _s0.interestRateBps = interestRate;
        _s0.repaidSoFarUSD = FHE.asEuint64(0);
        _s0.termWeeks = termWeeks;
        _s0.issuedAt = 0;
        _s0.approved = false;
        _s0.repaid = false;
        _s0.defaulted = false;
        FHE.allowThis(loans[loanId].requestedAmountUSD);
        FHE.allowThis(loans[loanId].approvedAmountUSD);
        FHE.allowThis(loans[loanId].weeklyRepaymentUSD);
        FHE.allowThis(loans[loanId].repaidSoFarUSD);
        FHE.allow(loans[loanId].weeklyRepaymentUSD, msg.sender);
        emit LoanRequested(loanId, groupId, msg.sender);
    }

    function approveLoan(uint256 loanId) external {
        require(isMFIAgent[msg.sender], "Not agent");
        LoanRequest storage loan = loans[loanId];
        require(!loan.approved, "Already approved");
        VillageGroup storage grp = groups[loan.groupId];
        // Check group fund availability
        ebool hasCapacity = FHE.ge(grp.loanFundUSD, loan.requestedAmountUSD);
        loan.approvedAmountUSD = FHE.select(hasCapacity, loan.requestedAmountUSD, grp.loanFundUSD);
        grp.loanFundUSD = FHE.sub(grp.loanFundUSD, loan.approvedAmountUSD);
        bytes32 key = keccak256(abi.encodePacked(loan.groupId, loan.member));
        accounts[key].loanBalance = loan.approvedAmountUSD;
        accounts[key].hasLoan = true;
        loan.approved = true;
        loan.issuedAt = block.timestamp;
        _totalNetworkLoans = FHE.add(_totalNetworkLoans, loan.approvedAmountUSD);
        FHE.allowThis(loan.approvedAmountUSD);
        FHE.allow(loan.approvedAmountUSD, loan.member);
        FHE.allowThis(accounts[key].loanBalance);
        FHE.allow(accounts[key].loanBalance, loan.member);
        FHE.allowThis(grp.loanFundUSD);
        FHE.allowThis(_totalNetworkLoans);
        emit LoanApproved(loanId);
    }

    function repayLoan(uint256 loanId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        LoanRequest storage loan = loans[loanId];
        require(loan.member == msg.sender && loan.approved && !loan.repaid, "Not eligible");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        loan.repaidSoFarUSD = FHE.add(loan.repaidSoFarUSD, amount);
        bytes32 key = keccak256(abi.encodePacked(loan.groupId, msg.sender));
        accounts[key].loanBalance = FHE.sub(accounts[key].loanBalance, amount);
        // Interest portion
        euint64 interest = FHE.div(FHE.mul(amount, loan.interestRateBps), 10000);
        groups[loan.groupId].interestEarnedUSD = FHE.add(groups[loan.groupId].interestEarnedUSD, interest);
        groups[loan.groupId].loanFundUSD = FHE.add(groups[loan.groupId].loanFundUSD, amount);
        // Improve repayment score
        accounts[key].repaymentScore = FHE.add(accounts[key].repaymentScore, FHE.asEuint64(10));
        ebool fullRepaid = FHE.le(loan.approvedAmountUSD, loan.repaidSoFarUSD);
        loan.repaid = true;
        accounts[key].hasLoan = false;
        FHE.allowThis(loan.repaidSoFarUSD);
        FHE.allow(loan.repaidSoFarUSD, msg.sender);
        FHE.allowThis(accounts[key].loanBalance);
        FHE.allow(accounts[key].loanBalance, msg.sender);
        FHE.allowThis(groups[loan.groupId].interestEarnedUSD);
        FHE.allowThis(groups[loan.groupId].loanFundUSD);
        FHE.allowThis(accounts[key].repaymentScore);
        emit LoanRepaid(loanId, msg.sender);
    }
}
