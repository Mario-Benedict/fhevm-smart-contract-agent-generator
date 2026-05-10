// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VotingEncryptedBoardDirectorElection
/// @notice Corporate board director election with encrypted shareholder votes.
///         Votes are weighted by encrypted share counts. Supports proxy voting
///         and encrypted campaign spend disclosure.
contract VotingEncryptedBoardDirectorElection is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ElectionStatus { Nomination, Campaigning, Voting, Counting, Certified }

    struct DirectorCandidate {
        address candidateAddr;
        string name;
        string biography;
        euint64 votesReceived;
        euint64 campaignSpendUSD;    // encrypted campaign spend
        euint32 independenceScore;   // encrypted independence rating
        bool nominated;
        bool disqualified;
    }

    struct ShareholderRecord {
        euint64 sharesOwned;         // encrypted share count
        euint32 votingPowerBps;      // encrypted effective voting power
        bool hasVoted;
        address proxyDelegate;
        bool active;
    }

    uint256 public candidateCount;
    ElectionStatus public electionStatus;
    uint256 public votingDeadline;
    uint256 public seatCount;        // number of seats open

    mapping(uint256 => DirectorCandidate) private candidates;
    mapping(address => ShareholderRecord) private shareholders;
    mapping(address => bool) public isCorporateSecretary;

    euint64 private _totalSharesVoted;
    euint64 private _totalSharesEligible;
    euint64 private _totalCampaignSpend;

    event CandidateNominated(uint256 indexed id, address candidate, string name);
    event ShareholderEnrolled(address indexed shareholder);
    event VoteCast(address indexed voter);
    event ProxyAssigned(address indexed from, address indexed to);
    event DirectorElected(uint256 indexed candidateId, address director);
    event ElectionStatusChanged(ElectionStatus newStatus);

    modifier onlySecretary() {
        require(isCorporateSecretary[msg.sender] || msg.sender == owner(), "Not corporate secretary");
        _;
    }

    constructor(uint256 _seatCount) Ownable(msg.sender) {
        seatCount = _seatCount;
        electionStatus = ElectionStatus.Nomination;
        _totalSharesVoted = FHE.asEuint64(0);
        _totalSharesEligible = FHE.asEuint64(0);
        _totalCampaignSpend = FHE.asEuint64(0);
        FHE.allowThis(_totalSharesVoted);
        FHE.allowThis(_totalSharesEligible);
        FHE.allowThis(_totalCampaignSpend);
        isCorporateSecretary[msg.sender] = true;
    }

    function addSecretary(address sec) external onlyOwner { isCorporateSecretary[sec] = true; }

    function nominateCandidate(
        address candidateAddr,
        string calldata name,
        string calldata biography,
        externalEuint32 encIndependence, bytes calldata indProof
    ) external onlySecretary {
        require(electionStatus == ElectionStatus.Nomination || electionStatus == ElectionStatus.Campaigning, "Wrong status");
        euint32 independence = FHE.fromExternal(encIndependence, indProof);
        uint256 id = candidateCount++;
        candidates[id].candidateAddr = candidateAddr;
        candidates[id].name = name;
        candidates[id].biography = biography;
        candidates[id].votesReceived = FHE.asEuint64(0);
        candidates[id].campaignSpendUSD = FHE.asEuint64(0);
        candidates[id].independenceScore = independence;
        candidates[id].nominated = true;
        candidates[id].disqualified = false;
        FHE.allowThis(candidates[id].votesReceived);
        FHE.allowThis(candidates[id].campaignSpendUSD);
        FHE.allowThis(candidates[id].independenceScore);
        emit CandidateNominated(id, candidateAddr, name);
    }

    function enrollShareholder(
        address shareholder,
        externalEuint64 encShares, bytes calldata sharesProof,
        externalEuint32 encVotingPower, bytes calldata vpProof
    ) external onlySecretary {
        euint64 shares = FHE.fromExternal(encShares, sharesProof);
        euint32 votingPower = FHE.fromExternal(encVotingPower, vpProof);
        ShareholderRecord storage rec = shareholders[shareholder];
        rec.sharesOwned = shares;
        rec.votingPowerBps = votingPower;
        rec.hasVoted = false;
        rec.active = true;
        _totalSharesEligible = FHE.add(_totalSharesEligible, shares); // [arithmetic_overflow_underflow]
        euint64 sharesScaled = FHE.mul(shares, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(rec.sharesOwned); FHE.allow(rec.sharesOwned, shareholder);
        FHE.allowThis(rec.votingPowerBps); FHE.allow(rec.votingPowerBps, shareholder);
        FHE.allowThis(_totalSharesEligible);
        emit ShareholderEnrolled(shareholder);
    }

    function assignProxy(address delegate) external {
        require(shareholders[msg.sender].active, "Not shareholder");
        require(!shareholders[msg.sender].hasVoted, "Already voted");
        shareholders[msg.sender].proxyDelegate = delegate;
        emit ProxyAssigned(msg.sender, delegate);
    }

    function castVote(uint256 candidateId) external nonReentrant {
        require(electionStatus == ElectionStatus.Voting, "Not voting phase");
        require(block.timestamp <= votingDeadline, "Voting ended");
        address effectiveVoter = shareholders[msg.sender].proxyDelegate != address(0)
            ? shareholders[msg.sender].proxyDelegate
            : msg.sender;
        require(shareholders[effectiveVoter].active, "Not shareholder");
        require(!shareholders[effectiveVoter].hasVoted, "Already voted");
        require(candidates[candidateId].nominated && !candidates[candidateId].disqualified, "Invalid candidate");

        shareholders[effectiveVoter].hasVoted = true;
        euint64 voteWeight = shareholders[effectiveVoter].sharesOwned;
        candidates[candidateId].votesReceived = FHE.add(candidates[candidateId].votesReceived, voteWeight);
        _totalSharesVoted = FHE.add(_totalSharesVoted, voteWeight);

        FHE.allowThis(candidates[candidateId].votesReceived);
        FHE.allowThis(_totalSharesVoted);
        emit VoteCast(effectiveVoter);
    }

    function reportCampaignSpend(
        uint256 candidateId,
        externalEuint64 encSpend, bytes calldata proof
    ) external {
        require(candidates[candidateId].candidateAddr == msg.sender, "Not candidate");
        euint64 spend = FHE.fromExternal(encSpend, proof);
        candidates[candidateId].campaignSpendUSD = FHE.add(candidates[candidateId].campaignSpendUSD, spend);
        _totalCampaignSpend = FHE.add(_totalCampaignSpend, spend);
        FHE.allowThis(candidates[candidateId].campaignSpendUSD);
        FHE.allow(candidates[candidateId].campaignSpendUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSharesVoted, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSharesEligible, msg.sender); // [acl_misconfig]
        FHE.allowThis(_totalCampaignSpend);
    }

    function advanceStatus(uint256 newVotingDeadline) external onlySecretary {
        require(uint8(electionStatus) < uint8(ElectionStatus.Certified), "Already certified");
        if (electionStatus == ElectionStatus.Campaigning) {
            votingDeadline = newVotingDeadline;
        }
        electionStatus = ElectionStatus(uint8(electionStatus) + 1);
        emit ElectionStatusChanged(electionStatus);
    }

    function certifyElection(uint256[] calldata winnerIds) external onlySecretary {
        require(electionStatus == ElectionStatus.Counting, "Not in counting");
        require(winnerIds.length == seatCount, "Wrong seat count");
        electionStatus = ElectionStatus.Certified;
        for (uint256 i = 0; i < winnerIds.length; i++) {
            FHE.allow(candidates[winnerIds[i]].votesReceived, candidates[winnerIds[i]].candidateAddr);
            emit DirectorElected(winnerIds[i], candidates[winnerIds[i]].candidateAddr);
        }
        emit ElectionStatusChanged(ElectionStatus.Certified);
    }

    function allowElectionStats(address viewer) external onlyOwner {
        FHE.allow(_totalSharesVoted, viewer);
        FHE.allow(_totalSharesEligible, viewer);
        FHE.allow(_totalCampaignSpend, viewer);
    }

    function allowCandidateView(uint256 candidateId, address viewer) external onlySecretary {
        FHE.allow(candidates[candidateId].votesReceived, viewer);
        FHE.allow(candidates[candidateId].campaignSpendUSD, viewer);
        FHE.allow(candidates[candidateId].independenceScore, viewer);
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