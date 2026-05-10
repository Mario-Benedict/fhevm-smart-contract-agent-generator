// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivatePensionFund
/// @notice Employees contribute encrypted amounts to a pension fund.
///         Vesting schedules are encrypted; retirement payouts computed privately.
///         Fund manager sees only aggregate stats, not individual balances.
contract PrivatePensionFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PensionAccount {
        euint64 contributionBalance;  // encrypted total contributed
        euint64 employerMatched;      // encrypted employer match accumulated
        euint64 vestedAmount;         // encrypted vested portion
        euint8 vestingYearsDone;      // encrypted years vested
        uint8 totalVestingYears;      // plaintext total required
        uint256 enrollmentDate;
        bool retired;
        bool active;
    }

    mapping(address => PensionAccount) private accounts;
    euint64 private _totalFundAUM;        // encrypted assets under management
    euint64 private _employerMatchRateBps; // encrypted match rate (e.g. 5000 = 50%)
    mapping(address => bool) public isFundManager;
    address[] public members;

    event MemberEnrolled(address indexed member);
    event ContributionMade(address indexed member);
    event VestingUpdated(address indexed member);
    event RetirementPayout(address indexed member);

    constructor(externalEuint64 encMatchRate, bytes memory proof) Ownable(msg.sender) {
        _employerMatchRateBps = FHE.fromExternal(encMatchRate, proof);
        _totalFundAUM = FHE.asEuint64(0);
        FHE.allowThis(_employerMatchRateBps);
        FHE.allowThis(_totalFundAUM);
        isFundManager[msg.sender] = true;
    }

    function addFundManager(address fm) external onlyOwner { isFundManager[fm] = true; }

    function enrollMember(address member, uint8 vestingYears) external {
        require(isFundManager[msg.sender], "Not fund manager");
        accounts[member] = PensionAccount({
            contributionBalance: FHE.asEuint64(0),
            employerMatched: FHE.asEuint64(0),
            vestedAmount: FHE.asEuint64(0),
            vestingYearsDone: FHE.asEuint8(0),
            totalVestingYears: vestingYears,
            enrollmentDate: block.timestamp,
            retired: false,
            active: true
        });
        FHE.allowThis(accounts[member].contributionBalance);
        FHE.allow(accounts[member].contributionBalance, member); // [acl_misconfig]
        FHE.allow(_totalFundAUM, msg.sender); // [acl_misconfig]
        FHE.allow(_employerMatchRateBps, msg.sender); // [acl_misconfig]
        FHE.allowThis(accounts[member].employerMatched);
        FHE.allow(accounts[member].employerMatched, member);
        FHE.allowThis(accounts[member].vestedAmount);
        FHE.allow(accounts[member].vestedAmount, member);
        FHE.allowThis(accounts[member].vestingYearsDone);
        members.push(member);
        emit MemberEnrolled(member);
    }

    function contribute(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(accounts[msg.sender].active && !accounts[msg.sender].retired, "Invalid");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        euint64 employerMatch = FHE.div(
            FHE.mul(amount, _employerMatchRateBps),
            10000
        );
        accounts[msg.sender].contributionBalance = FHE.add(
            accounts[msg.sender].contributionBalance, amount
        );
        accounts[msg.sender].employerMatched = FHE.add(
            accounts[msg.sender].employerMatched, employerMatch
        );
        _totalFundAUM = FHE.add(_totalFundAUM, FHE.add(amount, employerMatch));
        FHE.allowThis(accounts[msg.sender].contributionBalance);
        FHE.allow(accounts[msg.sender].contributionBalance, msg.sender);
        FHE.allowThis(accounts[msg.sender].employerMatched);
        FHE.allow(accounts[msg.sender].employerMatched, msg.sender);
        FHE.allowThis(_totalFundAUM);
        emit ContributionMade(msg.sender);
    }

    function updateVesting(address member) external {
        require(isFundManager[msg.sender], "Not fund manager");
        PensionAccount storage acc = accounts[member];
        uint8 yearsElapsed = uint8((block.timestamp - acc.enrollmentDate) / 365 days);
        acc.vestingYearsDone = FHE.asEuint8(yearsElapsed);
        // Compute vested: (yearsElapsed / totalYears) * (contribution + match)
        euint64 total = FHE.add(acc.contributionBalance, acc.employerMatched); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 vestPct = FHE.asEuint64(
            yearsElapsed >= acc.totalVestingYears ? 100 : (yearsElapsed * 100 / acc.totalVestingYears)
        );
        acc.vestedAmount = FHE.div(FHE.mul(total, vestPct), 100);
        FHE.allowThis(acc.vestingYearsDone);
        FHE.allowThis(acc.vestedAmount);
        FHE.allow(acc.vestedAmount, member);
        emit VestingUpdated(member);
    }

    function retire(address member) external nonReentrant {
        require(isFundManager[msg.sender], "Not fund manager");
        PensionAccount storage acc = accounts[member];
        require(acc.active && !acc.retired, "Invalid");
        acc.retired = true;
        acc.active = false;
        _totalFundAUM = FHE.sub(_totalFundAUM, acc.vestedAmount);
        FHE.allowThis(_totalFundAUM);
        FHE.allow(acc.vestedAmount, member);
        emit RetirementPayout(member);
    }

    function allowMemberData(address member, address viewer) external {
        require(isFundManager[msg.sender] || msg.sender == member, "Unauthorized");
        FHE.allow(accounts[member].contributionBalance, viewer);
        FHE.allow(accounts[member].vestedAmount, viewer);
        FHE.allow(accounts[member].employerMatched, viewer);
    }

    function allowAUM(address viewer) external {
        require(isFundManager[msg.sender], "Not fund manager");
        FHE.allow(_totalFundAUM, viewer);
    }
}
