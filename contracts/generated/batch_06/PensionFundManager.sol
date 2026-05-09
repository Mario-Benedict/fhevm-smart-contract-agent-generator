// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PensionFundManager
/// @notice Private pension fund: employees contribute to encrypted retirement
///         accounts, employer matches contributions, actuaries set encrypted
///         benefit formulas, and retirees receive private pension payments.
contract PensionFundManager is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct PensionAccount {
        euint64 employeeContributions;
        euint64 employerContributions;
        euint64 investmentReturns;
        euint64 vestedBalance;
        uint256 joinDate;
        bool active;
        bool retired;
    }

    mapping(address => PensionAccount) private accounts;
    mapping(address => bool) public isActuary;
    euint64 private _totalFundAssets;
    euint64 private _investmentReturn; // encrypted annual return rate bps
    euint64 private _vestingCliffMonths;
    address[] public memberList;

    event MemberEnrolled(address indexed member);
    event ContributionMade(address indexed member);
    event RetirementClaimed(address indexed member);

    constructor(externalEuint64 encReturnRate, bytes memory proof) Ownable(msg.sender) {
        _investmentReturn = FHE.fromExternal(encReturnRate, proof);
        _totalFundAssets = FHE.asEuint64(0);
        _vestingCliffMonths = FHE.asEuint64(24); // 2 years default
        FHE.allowThis(_investmentReturn);
        FHE.allowThis(_totalFundAssets);
        FHE.allowThis(_vestingCliffMonths);
        isActuary[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }

    function enroll() external {
        require(!accounts[msg.sender].active, "Already enrolled");
        accounts[msg.sender] = PensionAccount({
            employeeContributions: FHE.asEuint64(0),
            employerContributions: FHE.asEuint64(0),
            investmentReturns: FHE.asEuint64(0),
            vestedBalance: FHE.asEuint64(0),
            joinDate: block.timestamp,
            active: true,
            retired: false
        });
        FHE.allowThis(accounts[msg.sender].employeeContributions);
        FHE.allowThis(accounts[msg.sender].employerContributions);
        FHE.allowThis(accounts[msg.sender].investmentReturns);
        FHE.allowThis(accounts[msg.sender].vestedBalance);
        FHE.allow(accounts[msg.sender].employeeContributions, msg.sender);
        FHE.allow(accounts[msg.sender].vestedBalance, msg.sender);
        memberList.push(msg.sender);
        emit MemberEnrolled(msg.sender);
    }

    function contribute(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(accounts[msg.sender].active && !accounts[msg.sender].retired, "Invalid");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        accounts[msg.sender].employeeContributions = FHE.add(accounts[msg.sender].employeeContributions, amount);
        _totalFundAssets = FHE.add(_totalFundAssets, amount);
        FHE.allowThis(accounts[msg.sender].employeeContributions);
        FHE.allow(accounts[msg.sender].employeeContributions, msg.sender);
        FHE.allowThis(_totalFundAssets);
        emit ContributionMade(msg.sender);
    }

    function employerMatch(address member, externalEuint64 encAmount, bytes calldata proof) external onlyOwner nonReentrant {
        require(accounts[member].active, "Not active");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        accounts[member].employerContributions = FHE.add(accounts[member].employerContributions, amount);
        _totalFundAssets = FHE.add(_totalFundAssets, amount);
        FHE.allowThis(accounts[member].employerContributions);
        FHE.allow(accounts[member].employerContributions, member);
        FHE.allowThis(_totalFundAssets);
    }

    function applyReturns(address member) external {
        require(isActuary[msg.sender], "Not actuary");
        PensionAccount storage acc = accounts[member];
        euint64 totalBase = FHE.add(acc.employeeContributions, acc.employerContributions);
        euint64 returns_ = FHE.div(FHE.mul(totalBase, _investmentReturn), 10000);
        acc.investmentReturns = FHE.add(acc.investmentReturns, returns_);
        euint64 total = FHE.add(FHE.add(acc.employeeContributions, acc.employerContributions), acc.investmentReturns);
        // Vesting: employee gets their contributions + pro-rated employer match
        uint256 monthsEmployed = (block.timestamp - acc.joinDate) / 30 days;
        euint64 vestedPct = FHE.asEuint64(uint64(monthsEmployed >= 60 ? 100 : monthsEmployed * 100 / 60));
        euint64 vestedEmployer = FHE.div(FHE.mul(acc.employerContributions, vestedPct), 100);
        acc.vestedBalance = FHE.add(acc.employeeContributions, FHE.add(vestedEmployer, acc.investmentReturns));
        FHE.allowThis(acc.investmentReturns);
        FHE.allowThis(acc.vestedBalance);
        FHE.allow(acc.vestedBalance, member);
        FHE.allowThis(total);
    }

    function claimRetirement() external nonReentrant {
        PensionAccount storage acc = accounts[msg.sender];
        require(acc.active && !acc.retired, "Invalid");
        uint256 yearsEmployed = (block.timestamp - acc.joinDate) / 365 days;
        require(yearsEmployed >= 5, "Minimum 5 years");
        acc.retired = true;
        FHE.allow(acc.vestedBalance, msg.sender);
        emit RetirementClaimed(msg.sender);
    }

    function updateReturnRate(externalEuint64 encRate, bytes calldata proof) external {
        require(isActuary[msg.sender], "Not actuary");
        _investmentReturn = FHE.fromExternal(encRate, proof);
        FHE.allowThis(_investmentReturn);
    }

    function allowAccountDetails(address viewer) external {
        FHE.allow(accounts[msg.sender].vestedBalance, viewer);
        FHE.allow(accounts[msg.sender].employeeContributions, viewer);
    }
}
