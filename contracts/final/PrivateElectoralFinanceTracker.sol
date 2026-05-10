// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateElectoralFinanceTracker
/// @notice Political campaign finance tracker where donation amounts are encrypted.
///         Regulators can verify aggregate caps are not breached without seeing
///         individual donor amounts. Candidate war chests remain private.
contract PrivateElectoralFinanceTracker is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Candidate {
        euint64 totalRaised;
        euint64 totalSpent;
        euint64 cashOnHand;
        euint32 donorCount;
        bool registered;
        bool disqualified;
    }

    struct Donor {
        euint64 totalDonated;      // cumulative to all candidates
        euint32 donationCount;
        bool flagged;
    }

    mapping(address => Candidate) private candidates;
    mapping(address => Donor) private donors;
    mapping(address => mapping(address => euint64)) private donationPerCandidatePerDonor;
    address[] public candidateList;

    euint64 private _perDonorCap;        // max any donor can give
    euint64 private _perCandidateCap;    // max a candidate can raise
    euint64 private _totalSystemFlow;

    event CandidateRegistered(address indexed candidate);
    event DonationRecorded(address indexed donor, address indexed candidate);
    event CandidateDisqualified(address indexed candidate);
    event ExpenditureRecorded(address indexed candidate);

    constructor(
        externalEuint64 encDonorCap, bytes memory donorProof,
        externalEuint64 encCandidateCap, bytes memory candidateProof
    ) Ownable(msg.sender) {
        _perDonorCap = FHE.fromExternal(encDonorCap, donorProof);
        _perCandidateCap = FHE.fromExternal(encCandidateCap, candidateProof);
        _totalSystemFlow = FHE.asEuint64(0);
        FHE.allowThis(_perDonorCap);
        FHE.allowThis(_perCandidateCap);
        FHE.allowThis(_totalSystemFlow);
    }

    function registerCandidate(address candidate) external onlyOwner {
        require(!candidates[candidate].registered, "Already registered");
        candidates[candidate].totalRaised = FHE.asEuint64(0);
        candidates[candidate].totalSpent = FHE.asEuint64(0);
        candidates[candidate].cashOnHand = FHE.asEuint64(0);
        candidates[candidate].donorCount = FHE.asEuint32(0);
        candidates[candidate].registered = true;
        FHE.allowThis(candidates[candidate].totalRaised);
        FHE.allow(candidates[candidate].totalRaised, candidate);
        FHE.allowThis(candidates[candidate].cashOnHand);
        FHE.allow(candidates[candidate].cashOnHand, candidate);
        FHE.allowThis(candidates[candidate].totalSpent);
        FHE.allowThis(candidates[candidate].donorCount);
        candidateList.push(candidate);
        emit CandidateRegistered(candidate);
    }

    function donate(
        address candidate,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(candidates[candidate].registered, "Candidate not registered");
        require(!candidates[candidate].disqualified, "Candidate disqualified");
        require(!donors[msg.sender].flagged, "Donor flagged");
        // Initialize donor if first time
        if (!FHE.isInitialized(donors[msg.sender].totalDonated)) {
            // first donation — values start as uninitialized (zero by default in FHE)
        }
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Check donor cap
        euint64 newTotal = FHE.add(donors[msg.sender].totalDonated, amount);
        ebool withinDonorCap = FHE.le(newTotal, _perDonorCap);
        // Check candidate cap
        euint64 newCandidateTotal = FHE.add(candidates[candidate].totalRaised, amount);
        ebool withinCandidateCap = FHE.le(newCandidateTotal, _perCandidateCap);
        ebool valid = FHE.and(withinDonorCap, withinCandidateCap);
        euint64 actual = FHE.select(valid, amount, FHE.asEuint64(0));
        donors[msg.sender].totalDonated = FHE.add(donors[msg.sender].totalDonated, actual);
        donors[msg.sender].donationCount = FHE.add(donors[msg.sender].donationCount, FHE.asEuint32(1));
        candidates[candidate].totalRaised = FHE.add(candidates[candidate].totalRaised, actual);
        candidates[candidate].cashOnHand = FHE.add(candidates[candidate].cashOnHand, actual);
        candidates[candidate].donorCount = FHE.add(candidates[candidate].donorCount, FHE.asEuint32(1));
        donationPerCandidatePerDonor[msg.sender][candidate] = FHE.add(
            donationPerCandidatePerDonor[msg.sender][candidate], actual
        );
        _totalSystemFlow = FHE.add(_totalSystemFlow, actual);
        FHE.allowThis(donors[msg.sender].totalDonated);
        FHE.allow(donors[msg.sender].totalDonated, msg.sender);
        FHE.allowThis(donors[msg.sender].donationCount);
        FHE.allowThis(candidates[candidate].totalRaised);
        FHE.allow(candidates[candidate].totalRaised, candidate);
        FHE.allowThis(candidates[candidate].cashOnHand);
        FHE.allow(candidates[candidate].cashOnHand, candidate);
        FHE.allowThis(candidates[candidate].donorCount);
        FHE.allowThis(donationPerCandidatePerDonor[msg.sender][candidate]);
        FHE.allow(donationPerCandidatePerDonor[msg.sender][candidate], msg.sender);
        FHE.allow(donationPerCandidatePerDonor[msg.sender][candidate], candidate);
        FHE.allowThis(_totalSystemFlow);
        emit DonationRecorded(msg.sender, candidate);
    }

    function recordExpenditure(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(candidates[msg.sender].registered, "Not candidate");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasFunds = FHE.le(amount, candidates[msg.sender].cashOnHand);
        euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
        candidates[msg.sender].cashOnHand = FHE.sub(candidates[msg.sender].cashOnHand, actual);
        candidates[msg.sender].totalSpent = FHE.add(candidates[msg.sender].totalSpent, actual);
        FHE.allowThis(candidates[msg.sender].cashOnHand);
        FHE.allow(candidates[msg.sender].cashOnHand, msg.sender);
        FHE.allowThis(candidates[msg.sender].totalSpent);
        FHE.allow(candidates[msg.sender].totalSpent, msg.sender);
        emit ExpenditureRecorded(msg.sender);
    }

    function disqualifyCandidate(address candidate) external onlyOwner {
        candidates[candidate].disqualified = true;
        emit CandidateDisqualified(candidate);
    }

    function flagDonor(address donor) external onlyOwner {
        donors[donor].flagged = true;
    }

    function allowRegulatorView(address regulator, address candidate) external onlyOwner {
        FHE.allow(candidates[candidate].totalRaised, regulator);
        FHE.allow(candidates[candidate].cashOnHand, regulator);
        FHE.allow(candidates[candidate].totalSpent, regulator);
        FHE.allow(_totalSystemFlow, regulator);
    }

    function allowMyCandidateData(address viewer) external {
        require(candidates[msg.sender].registered, "Not candidate");
        FHE.allow(candidates[msg.sender].totalRaised, viewer);
        FHE.allow(candidates[msg.sender].cashOnHand, viewer);
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