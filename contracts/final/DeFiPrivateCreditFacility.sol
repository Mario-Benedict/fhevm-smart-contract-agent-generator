// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiPrivateCreditFacility
/// @notice Institutional credit facility with encrypted drawdown limits, utilization tracking,
///         and confidential interest rate tiers. Institutions can draw down and repay
///         without revealing their credit position to competitors.
contract DeFiPrivateCreditFacility is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct CreditLine {
        euint64 limit;              // encrypted credit limit
        euint64 utilized;           // encrypted amount drawn
        euint64 interestRateBps;    // encrypted rate tier
        euint64 accruedInterest;
        uint256 openedAt;
        uint256 lastAccrual;
        bool active;
    }

    mapping(address => CreditLine) private creditLines;
    address[] public institutions;
    euint64 private _totalFacility;
    euint64 private _totalUtilized;
    euint64 private _minimumLimitForPrime; // encrypted threshold for prime rate

    event CreditLineOpened(address indexed institution);
    event Drawdown(address indexed institution);
    event Repayment(address indexed institution);

    constructor(
        externalEuint64 encTotalFacility, bytes memory tProof,
        externalEuint64 encPrimeThreshold, bytes memory pProof
    ) Ownable(msg.sender) {
        _totalFacility = FHE.fromExternal(encTotalFacility, tProof);
        _minimumLimitForPrime = FHE.fromExternal(encPrimeThreshold, pProof);
        _totalUtilized = FHE.asEuint64(0);
        FHE.allowThis(_totalFacility);
        FHE.allowThis(_minimumLimitForPrime);
        FHE.allowThis(_totalUtilized);
    }

    function openCreditLine(
        address institution,
        externalEuint64 encLimit, bytes calldata lProof,
        externalEuint64 encRate, bytes calldata rProof
    ) external onlyOwner {
        require(!creditLines[institution].active, "Already active");
        euint64 limit = FHE.fromExternal(encLimit, lProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        creditLines[institution] = CreditLine({
            limit: limit, utilized: FHE.asEuint64(0),
            interestRateBps: rate, accruedInterest: FHE.asEuint64(0),
            openedAt: block.timestamp, lastAccrual: block.timestamp, active: true
        });
        FHE.allowThis(creditLines[institution].limit);
        FHE.allow(creditLines[institution].limit, institution);
        FHE.allowThis(creditLines[institution].utilized);
        FHE.allow(creditLines[institution].utilized, institution);
        FHE.allowThis(creditLines[institution].interestRateBps);
        FHE.allowThis(creditLines[institution].accruedInterest);
        FHE.allow(creditLines[institution].accruedInterest, institution);
        institutions.push(institution);
        emit CreditLineOpened(institution);
    }

    function drawdown(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        CreditLine storage cl = creditLines[msg.sender];
        require(cl.active, "No credit line");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool _safeSub120 = FHE.ge(cl.limit, cl.utilized);
        euint64 available = FHE.select(_safeSub120, FHE.sub(cl.limit, cl.utilized), FHE.asEuint64(0));
        ebool hasRoom = FHE.le(amount, available);
        euint64 actual = FHE.select(hasRoom, amount, FHE.asEuint64(0));
        cl.utilized = FHE.add(cl.utilized, actual);
        _totalUtilized = FHE.add(_totalUtilized, actual);
        FHE.allowThis(cl.utilized);
        FHE.allow(cl.utilized, msg.sender);
        FHE.allow(actual, msg.sender);
        FHE.allowThis(_totalUtilized);
        emit Drawdown(msg.sender);
    }

    function accrueInterest(address institution) external {
        CreditLine storage cl = creditLines[institution];
        require(cl.active, "No credit line");
        uint256 daysSince = (block.timestamp - cl.lastAccrual) / 1 days;
        if (daysSince == 0) return;
        ebool _safeMul26 = FHE.le(FHE.mul(cl.utilized, cl.interestRateBps), FHE.asEuint64(type(uint32).max));
        euint64 interest = FHE.select(_safeMul26, FHE.div(
            FHE.mul(FHE.mul(cl.utilized, cl.interestRateBps), FHE.asEuint64(uint64(daysSince))),
            3650000 // daily rate approximation
        ), FHE.asEuint64(uint64(type(uint32).max)));
        cl.accruedInterest = FHE.add(cl.accruedInterest, interest);
        cl.lastAccrual = block.timestamp;
        FHE.allowThis(cl.accruedInterest);
        FHE.allow(cl.accruedInterest, institution);
    }

    function repay(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        CreditLine storage cl = creditLines[msg.sender];
        require(cl.active, "No credit line");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Pay interest first
        ebool coversInterest = FHE.ge(amount, cl.accruedInterest);
        euint64 interestPaid = FHE.select(coversInterest, cl.accruedInterest, amount);
        euint64 principalPaid = FHE.select(coversInterest, FHE.sub(amount, cl.accruedInterest), FHE.asEuint64(0));
        ebool _safeSub121 = FHE.ge(cl.accruedInterest, interestPaid);
        cl.accruedInterest = FHE.select(_safeSub121, FHE.sub(cl.accruedInterest, interestPaid), FHE.asEuint64(0));
        ebool _safeSub122 = FHE.ge(cl.utilized, principalPaid);
        cl.utilized = FHE.select(_safeSub122, FHE.sub(cl.utilized, principalPaid), FHE.asEuint64(0));
        ebool _safeSub123 = FHE.ge(_totalUtilized, principalPaid);
        _totalUtilized = FHE.select(_safeSub123, FHE.sub(_totalUtilized, principalPaid), FHE.asEuint64(0));
        FHE.allowThis(cl.accruedInterest);
        FHE.allowThis(cl.utilized);
        FHE.allow(cl.utilized, msg.sender);
        FHE.allowThis(_totalUtilized);
        emit Repayment(msg.sender);
    }

    function closeCreditLine(address institution) external onlyOwner {
        creditLines[institution].active = false;
    }

    function allowCreditData(address viewer) external {
        FHE.allow(creditLines[msg.sender].limit, viewer);
        FHE.allow(creditLines[msg.sender].utilized, viewer);
        FHE.allow(creditLines[msg.sender].accruedInterest, viewer);
    }
}
