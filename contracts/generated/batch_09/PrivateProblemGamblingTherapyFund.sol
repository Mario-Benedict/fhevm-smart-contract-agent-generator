// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateProblemGamblingTherapyFund
/// @notice A confidential charitable fund for problem gambling rehabilitation.
///         Donation amounts, recipient identities, and treatment costs are encrypted
///         to protect both donors and beneficiaries from stigma and privacy violations.
contract PrivateProblemGamblingTherapyFund is
    ZamaEthereumConfig,
    Ownable,
    ReentrancyGuard
{
    struct Beneficiary {
        euint64 treatmentCostApproved; // encrypted approved treatment budget
        euint64 amountDisbursed; // total disbursed
        euint32 riskSeverityScore; // 0-10000 problem gambling severity
        euint32 sessionsCompleted;
        euint32 sessionsApproved;
        bool enrolled;
        bool graduated;
        uint256 enrollDate;
    }

    struct Donor {
        euint64 totalDonated;
        euint32 donationTier; // 1-4 tier
        bool _anonymous;
    }

    mapping(address => Beneficiary) private beneficiaries;
    mapping(address => Donor) private donors;
    address[] public beneficiaryList;

    euint64 private _fundBalance;
    euint64 private _totalDonated;
    euint64 private _totalDisbursed;
    euint32 private _avgSeverityScore; // population statistic
    uint256 public activeBeneficiaryCount;

    event BeneficiaryEnrolled(address indexed beneficiary);
    event TreatmentApproved(address indexed beneficiary);
    event SessionCompleted(address indexed beneficiary);
    event DonationReceived(address indexed donor);
    event FundDisbursed(address indexed beneficiary);
    event BeneficiaryGraduated(address indexed beneficiary);

    constructor() Ownable(msg.sender) {
        _fundBalance = FHE.asEuint64(0);
        _totalDonated = FHE.asEuint64(0);
        _totalDisbursed = FHE.asEuint64(0);
        _avgSeverityScore = FHE.asEuint32(0);
        FHE.allowThis(_fundBalance);
        FHE.allowThis(_totalDonated);
        FHE.allowThis(_totalDisbursed);
        FHE.allowThis(_avgSeverityScore);
    }

    function donate(
        externalEuint64 encAmount,
        bytes calldata proof,
        bool isAnonymous
    ) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _fundBalance = FHE.add(_fundBalance, amount);
        _totalDonated = FHE.add(_totalDonated, amount);
        if (!FHE.isInitialized(donors[msg.sender].totalDonated)) {
            donors[msg.sender].totalDonated = FHE.asEuint64(0);
            FHE.allowThis(donors[msg.sender].totalDonated);
        }
        donors[msg.sender].totalDonated = FHE.add(
            donors[msg.sender].totalDonated,
            amount
        );
        donors[msg.sender]._anonymous = isAnonymous;
        FHE.allowThis(donors[msg.sender].totalDonated);
        if (!isAnonymous) {
            FHE.allow(donors[msg.sender].totalDonated, msg.sender);
        }
        FHE.allowThis(_fundBalance);
        FHE.allowThis(_totalDonated);
        emit DonationReceived(msg.sender);
    }

    function enrollBeneficiary(
        address beneficiary,
        externalEuint32 encSeverity,
        bytes calldata sevProof,
        externalEuint32 encSessions,
        bytes calldata sessProof
    ) external onlyOwner {
        require(!beneficiaries[beneficiary].enrolled, "Already enrolled");
        beneficiaries[beneficiary].riskSeverityScore = FHE.fromExternal(
            encSeverity,
            sevProof
        );
        beneficiaries[beneficiary].sessionsApproved = FHE.fromExternal(
            encSessions,
            sessProof
        );
        beneficiaries[beneficiary].sessionsCompleted = FHE.asEuint32(0);
        beneficiaries[beneficiary].treatmentCostApproved = FHE.asEuint64(0);
        beneficiaries[beneficiary].amountDisbursed = FHE.asEuint64(0);
        beneficiaries[beneficiary].enrolled = true;
        beneficiaries[beneficiary].enrollDate = block.timestamp;
        FHE.allowThis(beneficiaries[beneficiary].riskSeverityScore);
        FHE.allowThis(beneficiaries[beneficiary].sessionsApproved);
        FHE.allow(beneficiaries[beneficiary].sessionsApproved, beneficiary);
        FHE.allowThis(beneficiaries[beneficiary].sessionsCompleted);
        FHE.allow(beneficiaries[beneficiary].sessionsCompleted, beneficiary);
        FHE.allowThis(beneficiaries[beneficiary].treatmentCostApproved);
        FHE.allowThis(beneficiaries[beneficiary].amountDisbursed);
        FHE.allow(beneficiaries[beneficiary].amountDisbursed, beneficiary);
        beneficiaryList.push(beneficiary);
        activeBeneficiaryCount++;
        emit BeneficiaryEnrolled(beneficiary);
    }

    function approveTreatmentBudget(
        address beneficiary,
        externalEuint64 encBudget,
        bytes calldata proof
    ) external onlyOwner {
        require(beneficiaries[beneficiary].enrolled, "Not enrolled");
        euint64 budget = FHE.fromExternal(encBudget, proof);
        ebool fundSufficient = FHE.le(budget, _fundBalance);
        euint64 approved = FHE.select(fundSufficient, budget, _fundBalance);
        beneficiaries[beneficiary].treatmentCostApproved = approved;
        FHE.allowThis(beneficiaries[beneficiary].treatmentCostApproved);
        FHE.allow(
            beneficiaries[beneficiary].treatmentCostApproved,
            beneficiary
        );
        emit TreatmentApproved(beneficiary);
    }

    function recordSessionCompletion(address beneficiary) external onlyOwner {
        require(
            beneficiaries[beneficiary].enrolled &&
                !beneficiaries[beneficiary].graduated,
            "Not active"
        );
        beneficiaries[beneficiary].sessionsCompleted = FHE.add(
            beneficiaries[beneficiary].sessionsCompleted,
            FHE.asEuint32(1)
        );
        FHE.allowThis(beneficiaries[beneficiary].sessionsCompleted);
        FHE.allow(beneficiaries[beneficiary].sessionsCompleted, beneficiary);
        emit SessionCompleted(beneficiary);
    }

    function disburseFunds(
        address beneficiary,
        externalEuint64 encAmount,
        bytes calldata proof
    ) external onlyOwner nonReentrant {
        require(
            beneficiaries[beneficiary].enrolled &&
                !beneficiaries[beneficiary].graduated,
            "Not active"
        );
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinBudget = FHE.le(
            FHE.add(beneficiaries[beneficiary].amountDisbursed, amount),
            beneficiaries[beneficiary].treatmentCostApproved
        );
        ebool fundSufficient = FHE.le(amount, _fundBalance);
        ebool canDisburse = FHE.and(withinBudget, fundSufficient);
        euint64 actual = FHE.select(canDisburse, amount, FHE.asEuint64(0));
        beneficiaries[beneficiary].amountDisbursed = FHE.add(
            beneficiaries[beneficiary].amountDisbursed,
            actual
        );
        _fundBalance = FHE.sub(_fundBalance, actual);
        _totalDisbursed = FHE.add(_totalDisbursed, actual);
        FHE.allowThis(beneficiaries[beneficiary].amountDisbursed);
        FHE.allow(beneficiaries[beneficiary].amountDisbursed, beneficiary);
        FHE.allow(actual, beneficiary);
        FHE.allowThis(_fundBalance);
        FHE.allowThis(_totalDisbursed);
        emit FundDisbursed(beneficiary);
    }

    function graduateBeneficiary(address beneficiary) external onlyOwner {
        require(
            beneficiaries[beneficiary].enrolled &&
                !beneficiaries[beneficiary].graduated,
            "Not active"
        );
        beneficiaries[beneficiary].graduated = true;
        activeBeneficiaryCount--;
        emit BeneficiaryGraduated(beneficiary);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_fundBalance, viewer);
        FHE.allow(_totalDonated, viewer);
        FHE.allow(_totalDisbursed, viewer);
    }

    function allowMyData(address viewer) external {
        require(beneficiaries[msg.sender].enrolled, "Not beneficiary");
        FHE.allow(beneficiaries[msg.sender].amountDisbursed, viewer);
        FHE.allow(beneficiaries[msg.sender].sessionsCompleted, viewer);
    }
}
