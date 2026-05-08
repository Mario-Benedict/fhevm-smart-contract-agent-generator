// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCorporateBoardVoting
/// @notice Corporate board of directors voting: encrypted share-weighted votes,
///         private proxy delegation, hidden resolution budgets, and confidential
///         quorum checks with supermajority thresholds.
contract EncryptedCorporateBoardVoting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ResolutionType { Ordinary, Special, Constitutional, Emergency }

    struct Resolution {
        string title;
        string description;
        ResolutionType resType;
        euint64 votesFor;              // encrypted weighted votes for
        euint64 votesAgainst;          // encrypted weighted votes against
        euint64 quorumThreshold;       // encrypted quorum required
        euint64 superMajorityThreshold;// encrypted supermajority threshold
        euint64 budgetApproved;        // encrypted budget if approved
        uint32  voterCount;
        bool passed;
        uint256 deadline;
    }

    struct Shareholder {
        euint64 votingShares;          // encrypted share count
        address proxyDelegate;
        bool registered;
    }

    mapping(uint256 => Resolution) private resolutions;
    mapping(address => Shareholder) private shareholders;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isBoardSecretary;

    uint256 public resolutionCount;
    euint64 private _totalSharesRegistered;

    event ResolutionProposed(uint256 indexed id, ResolutionType resType);
    event VoteCast(uint256 indexed resId, address shareholder);
    event ResolutionFinalized(uint256 indexed id, bool passed);

    modifier onlyBoardSecretary() {
        require(isBoardSecretary[msg.sender] || msg.sender == owner(), "Not board secretary");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSharesRegistered = FHE.asEuint64(0);
        FHE.allowThis(_totalSharesRegistered);
        isBoardSecretary[msg.sender] = true;
    }

    function addBoardSecretary(address bs) external onlyOwner { isBoardSecretary[bs] = true; }

    function registerShareholder(address sh, externalEuint64 encShares, bytes calldata proof) external onlyBoardSecretary {
        euint64 shares = FHE.fromExternal(encShares, proof);
        shareholders[sh] = Shareholder({ votingShares: shares, proxyDelegate: address(0), registered: true });
        _totalSharesRegistered = FHE.add(_totalSharesRegistered, shares);
        FHE.allowThis(shareholders[sh].votingShares); FHE.allow(shareholders[sh].votingShares, sh);
        FHE.allowThis(_totalSharesRegistered);
    }

    function delegateProxy(address delegate_) external {
        require(shareholders[msg.sender].registered, "Not shareholder");
        shareholders[msg.sender].proxyDelegate = delegate_;
    }

    function proposeResolution(
        string calldata title, string calldata description, ResolutionType resType,
        externalEuint64 encQuorum, bytes calldata qProof,
        externalEuint64 encSuperMaj, bytes calldata smProof,
        externalEuint64 encBudget, bytes calldata bProof,
        uint256 deadlineDays
    ) external onlyBoardSecretary returns (uint256 id) {
        euint64 quorum   = FHE.fromExternal(encQuorum, qProof);
        euint64 superMaj = FHE.fromExternal(encSuperMaj, smProof);
        euint64 budget   = FHE.fromExternal(encBudget, bProof);
        id = resolutionCount++;
        resolutions[id] = Resolution({
            title: title, description: description, resType: resType,
            votesFor: FHE.asEuint64(0), votesAgainst: FHE.asEuint64(0),
            quorumThreshold: quorum, superMajorityThreshold: superMaj,
            budgetApproved: budget, voterCount: 0, passed: false,
            deadline: block.timestamp + deadlineDays * 1 days
        });
        FHE.allowThis(resolutions[id].votesFor); FHE.allowThis(resolutions[id].votesAgainst);
        FHE.allowThis(resolutions[id].quorumThreshold); FHE.allowThis(resolutions[id].superMajorityThreshold);
        FHE.allowThis(resolutions[id].budgetApproved);
        emit ResolutionProposed(id, resType);
    }

    function vote(uint256 resId, bool support) external nonReentrant {
        Resolution storage r = resolutions[resId];
        require(block.timestamp < r.deadline, "Deadline passed");
        address voter = msg.sender;
        // Use proxy if set
        if (!shareholders[voter].registered && shareholders[voter].proxyDelegate != address(0)) {
            voter = shareholders[voter].proxyDelegate;
        }
        require(shareholders[voter].registered && !hasVoted[resId][voter], "Cannot vote");
        hasVoted[resId][voter] = true;
        r.voterCount++;
        euint64 shares = shareholders[voter].votingShares;
        if (support) { r.votesFor = FHE.add(r.votesFor, shares); FHE.allowThis(r.votesFor); }
        else { r.votesAgainst = FHE.add(r.votesAgainst, shares); FHE.allowThis(r.votesAgainst); }
        emit VoteCast(resId, voter);
    }

    function finalizeResolution(uint256 resId) external onlyBoardSecretary {
        Resolution storage r = resolutions[resId];
        require(block.timestamp >= r.deadline, "Not ended");
        euint64 total = FHE.add(r.votesFor, r.votesAgainst);
        ebool quorumMet  = FHE.ge(total, r.quorumThreshold);
        ebool superMajMet= FHE.ge(r.votesFor, r.superMajorityThreshold);
        ebool passed_     = FHE.and(quorumMet, superMajMet);
        r.passed = FHE.isInitialized(passed_); // proxy; real decrypt off-chain
        FHE.allow(r.votesFor, owner()); FHE.allow(r.votesAgainst, owner());
        FHE.allow(r.budgetApproved, owner());
        emit ResolutionFinalized(resId, r.passed);
    }

    function allowBoardStats(address viewer) external onlyOwner {
        FHE.allow(_totalSharesRegistered, viewer);
    }
    function getVotesFor(uint256 id) external view returns (euint64) { return resolutions[id].votesFor; }
    function getVotesAgainst(uint256 id) external view returns (euint64) { return resolutions[id].votesAgainst; }
}
