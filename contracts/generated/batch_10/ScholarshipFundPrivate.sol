// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ScholarshipFundPrivate
/// @notice Private scholarship fund: donors contribute anonymously, committee
///         evaluates encrypted merit scores, and grants are distributed privately.
contract ScholarshipFundPrivate is ZamaEthereumConfig, Ownable {
    struct Applicant {
        address addr;
        euint16 meritScore;      // encrypted 0-1000
        euint64 requestedAmount;
        euint64 grantedAmount;
        bool evaluated;
        bool granted;
    }

    mapping(uint256 => Applicant) private applicants;
    mapping(address => bool) public isCommitteeMember;
    mapping(address => euint64) private _donorContributions;
    uint256 public nextApplicantId;
    euint64 private _totalFund;
    euint64 private _disbursed;
    euint16 private _minimumMeritScore;
    bool public applicationOpen;

    event ApplicationSubmitted(uint256 indexed id);
    event GrantAwarded(uint256 indexed id);
    event DonationReceived(address donor);

    constructor(externalEuint16 encMinScore, bytes memory proof) Ownable(msg.sender) {
        _minimumMeritScore = FHE.fromExternal(encMinScore, proof);
        _totalFund = FHE.asEuint64(0);
        _disbursed = FHE.asEuint64(0);
        FHE.allowThis(_minimumMeritScore);
        FHE.allowThis(_totalFund);
        FHE.allowThis(_disbursed);
        isCommitteeMember[msg.sender] = true;
    }

    function addCommitteeMember(address m) external onlyOwner { isCommitteeMember[m] = true; }

    function donate(externalEuint64 encAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalFund = FHE.add(_totalFund, amount);
        _donorContributions[msg.sender] = FHE.add(_donorContributions[msg.sender], amount);
        FHE.allowThis(_totalFund);
        FHE.allowThis(_donorContributions[msg.sender]);
        FHE.allow(_donorContributions[msg.sender], msg.sender);
        emit DonationReceived(msg.sender);
    }

    function applyForScholarship(externalEuint64 encRequestedAmount, bytes calldata proof) external returns (uint256 id) {
        require(applicationOpen, "Applications closed");
        euint64 requested = FHE.fromExternal(encRequestedAmount, proof);
        id = nextApplicantId++;
        applicants[id] = Applicant({
            addr: msg.sender,
            meritScore: FHE.asEuint16(0),
            requestedAmount: requested,
            grantedAmount: FHE.asEuint64(0),
            evaluated: false,
            granted: false
        });
        FHE.allowThis(applicants[id].meritScore);
        FHE.allowThis(applicants[id].requestedAmount);
        FHE.allow(applicants[id].requestedAmount, msg.sender);
        FHE.allowThis(applicants[id].grantedAmount);
        emit ApplicationSubmitted(id);
    }

    function evaluateApplicant(uint256 applicantId, externalEuint16 encScore, bytes calldata proof)
        external
    {
        require(isCommitteeMember[msg.sender], "Not committee");
        Applicant storage a = applicants[applicantId];
        require(!a.evaluated, "Already evaluated");
        euint16 score = FHE.fromExternal(encScore, proof);
        a.meritScore = score;
        a.evaluated = true;
        FHE.allowThis(a.meritScore);
        FHE.allow(a.meritScore, owner());
    }

    function awardGrant(uint256 applicantId) external {
        require(isCommitteeMember[msg.sender], "Not committee");
        Applicant storage a = applicants[applicantId];
        require(a.evaluated && !a.granted, "Invalid state");
        ebool meetsMin = FHE.ge(a.meritScore, _minimumMeritScore);
        ebool fundAvailable = FHE.ge(_totalFund, a.requestedAmount);
        ebool canGrant = FHE.and(meetsMin, fundAvailable);
        euint64 grant = FHE.select(canGrant, a.requestedAmount, FHE.asEuint64(0));
        a.grantedAmount = grant;
        a.granted = true;
        _totalFund = FHE.sub(_totalFund, grant);
        _disbursed = FHE.add(_disbursed, grant);
        FHE.allowThis(a.grantedAmount);
        FHE.allow(a.grantedAmount, a.addr);
        FHE.allowThis(_totalFund);
        FHE.allowThis(_disbursed);
        emit GrantAwarded(applicantId);
    }

    function openApplications() external onlyOwner { applicationOpen = true; }
    function closeApplications() external onlyOwner { applicationOpen = false; }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalFund, viewer);
        FHE.allow(_disbursed, viewer);
    }
}
