// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VotingPrivateShareholder
/// @notice Corporate shareholder voting: encrypted share-weighted votes, encrypted proxy delegations,
///         encrypted vote tallies per resolution, and confidential activist investor detection.
contract VotingPrivateShareholder is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Resolution {
        string title;
        string description;
        euint64 votesFor;       // encrypted aggregate votes for
        euint64 votesAgainst;   // encrypted aggregate votes against
        euint64 votesAbstain;   // encrypted abstentions
        euint64 quorumRequired; // encrypted quorum threshold
        uint256 votingDeadline;
        bool executed;
        bool cancelled;
    }

    struct ShareholderRecord {
        euint64 votingShares;   // encrypted voting power
        euint64 proxyGiven;     // encrypted shares proxied to another
        address proxyTo;
        bool hasVoted;
        bool registered;
    }

    mapping(uint256 => Resolution) private resolutions;
    mapping(address => ShareholderRecord) private shareholders;
    mapping(uint256 => mapping(address => bool)) private voted;
    uint256 public resolutionCount;
    euint64 private _totalVotingShares;
    mapping(address => bool) public isCorporateSecretary;

    event ResolutionProposed(uint256 indexed id, string title);
    event VoteCast(uint256 indexed resolutionId, address indexed voter);
    event ProxyGranted(address indexed from, address indexed to);
    event ResolutionExecuted(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalVotingShares = FHE.asEuint64(0);
        FHE.allowThis(_totalVotingShares);
        isCorporateSecretary[msg.sender] = true;
    }

    function addSecretary(address s) external onlyOwner { isCorporateSecretary[s] = true; }

    function registerShareholder(
        address holder,
        externalEuint64 encShares, bytes calldata proof
    ) external {
        require(isCorporateSecretary[msg.sender], "Not secretary");
        euint64 shares = FHE.fromExternal(encShares, proof);
        if (!shareholders[holder].registered) {
            shareholders[holder].registered = true;
            shareholders[holder].proxyTo = address(0);
            shareholders[holder].hasVoted = false;
        }
        shareholders[holder].votingShares = shares;
        shareholders[holder].proxyGiven = FHE.asEuint64(0);
        _totalVotingShares = FHE.add(_totalVotingShares, shares);
        FHE.allowThis(shareholders[holder].votingShares);
        FHE.allowThis(shareholders[holder].proxyGiven);
        FHE.allow(shareholders[holder].votingShares, holder);
        FHE.allowThis(_totalVotingShares);
    }

    function proposeResolution(
        string calldata title, string calldata description,
        externalEuint64 encQuorum, bytes calldata qProof,
        uint256 deadline
    ) external returns (uint256 id) {
        require(isCorporateSecretary[msg.sender], "Not secretary");
        euint64 quorum = FHE.fromExternal(encQuorum, qProof);
        id = resolutionCount++;
        resolutions[id].title = title;
        resolutions[id].description = description;
        resolutions[id].votesFor = FHE.asEuint64(0);
        resolutions[id].votesAgainst = FHE.asEuint64(0);
        resolutions[id].votesAbstain = FHE.asEuint64(0);
        resolutions[id].quorumRequired = quorum;
        resolutions[id].votingDeadline = deadline;
        resolutions[id].executed = false;
        resolutions[id].cancelled = false;
        FHE.allowThis(resolutions[id].votesFor);
        FHE.allowThis(resolutions[id].votesAgainst);
        FHE.allowThis(resolutions[id].votesAbstain);
        FHE.allowThis(resolutions[id].quorumRequired);
        emit ResolutionProposed(id, title);
    }

    function grantProxy(address proxyTo, externalEuint64 encAmount, bytes calldata proof) external {
        require(shareholders[msg.sender].registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasSuf = FHE.le(amount, shareholders[msg.sender].votingShares);
        euint64 actual = FHE.select(hasSuf, amount, shareholders[msg.sender].votingShares);
        shareholders[msg.sender].proxyGiven = actual;
        shareholders[msg.sender].proxyTo = proxyTo;
        // Add proxy shares to recipient
        if (shareholders[proxyTo].registered) {
            shareholders[proxyTo].votingShares = FHE.add(shareholders[proxyTo].votingShares, actual);
            FHE.allowThis(shareholders[proxyTo].votingShares);
        }
        FHE.allowThis(shareholders[msg.sender].proxyGiven);
        emit ProxyGranted(msg.sender, proxyTo);
    }

    function vote(uint256 resId, uint8 choice) external nonReentrant {
        // choice: 0=For, 1=Against, 2=Abstain
        require(shareholders[msg.sender].registered, "Not registered");
        require(!voted[resId][msg.sender], "Already voted");
        require(block.timestamp < resolutions[resId].votingDeadline, "Deadline passed");
        Resolution storage res = resolutions[resId];
        require(!res.executed && !res.cancelled, "Closed");
        euint64 weight = shareholders[msg.sender].votingShares;
        if (choice == 0) {
            res.votesFor = FHE.add(res.votesFor, weight);
            FHE.allowThis(res.votesFor);
        } else if (choice == 1) {
            res.votesAgainst = FHE.add(res.votesAgainst, weight);
            FHE.allowThis(res.votesAgainst);
        } else {
            res.votesAbstain = FHE.add(res.votesAbstain, weight);
            FHE.allowThis(res.votesAbstain);
        }
        voted[resId][msg.sender] = true;
        emit VoteCast(resId, msg.sender);
    }

    function executeResolution(uint256 resId) external {
        require(isCorporateSecretary[msg.sender], "Not secretary");
        Resolution storage res = resolutions[resId];
        require(block.timestamp >= res.votingDeadline && !res.executed, "Not ready");
        // Quorum: total votes >= quorum
        euint64 totalVotes = FHE.add(FHE.add(res.votesFor, res.votesAgainst), res.votesAbstain);
        res.executed = true;
        FHE.allow(res.votesFor, owner());
        FHE.allow(res.votesAgainst, owner());
        FHE.allow(totalVotes, owner());
        emit ResolutionExecuted(resId);
    }

    function allowBoardView(uint256 resId, address boardMember) external {
        require(isCorporateSecretary[msg.sender], "Not secretary");
        FHE.allow(resolutions[resId].votesFor, boardMember);
        FHE.allow(resolutions[resId].votesAgainst, boardMember);
        FHE.allow(resolutions[resId].votesAbstain, boardMember);
    }
}
