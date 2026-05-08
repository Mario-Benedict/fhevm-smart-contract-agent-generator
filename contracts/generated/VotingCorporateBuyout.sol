// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCorporateBuyout
/// @notice M&A shareholder approval vote. Each shareholder's share count is encrypted.
///         The buyout approval threshold (% of total shares) is also encrypted.
///         Shareholders vote to accept or reject the buyout offer.
contract VotingCorporateBuyout is ZamaEthereumConfig, Ownable {
    struct Shareholder {
        euint64 shareCount;
        bool voted;
        bool approves;
    }

    mapping(address => Shareholder) private shareholders;
    address[] public shareholderList;
    euint64 private _totalShares;
    euint64 private _approvalVotes;
    euint64 private _rejectionVotes;
    euint64 private _approvalThresholdBps; // e.g. 6700 = 67%
    bool public voteOpen;
    bool public buyoutApproved;
    string public buyoutDescription;

    event ShareholderRegistered(address indexed s);
    event VoteCast(address indexed s, bool approves);
    event BuyoutResult(bool approved);

    constructor(
        string memory description,
        externalEuint64 encThreshold, bytes memory proof
    ) Ownable(msg.sender) {
        buyoutDescription = description;
        _approvalThresholdBps = FHE.fromExternal(encThreshold, proof);
        _totalShares = FHE.asEuint64(0);
        _approvalVotes = FHE.asEuint64(0);
        _rejectionVotes = FHE.asEuint64(0);
        FHE.allowThis(_approvalThresholdBps);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_approvalVotes);
        FHE.allowThis(_rejectionVotes);
        voteOpen = false;
    }

    function registerShareholder(address s, externalEuint64 encShares, bytes calldata proof) external onlyOwner {
        euint64 shares = FHE.fromExternal(encShares, proof);
        shareholders[s].shareCount = shares;
        _totalShares = FHE.add(_totalShares, shares);
        FHE.allowThis(shareholders[s].shareCount);
        FHE.allow(shareholders[s].shareCount, s);
        FHE.allowThis(_totalShares);
        shareholderList.push(s);
        emit ShareholderRegistered(s);
    }

    function openVote() external onlyOwner { voteOpen = true; }

    function castVote(bool approves) external {
        require(voteOpen, "Vote not open");
        Shareholder storage sh = shareholders[msg.sender];
        require(!sh.voted, "Already voted");
        require(FHE.isInitialized(sh.shareCount), "Not shareholder");
        sh.voted = true;
        sh.approves = approves;
        if (approves) {
            _approvalVotes = FHE.add(_approvalVotes, sh.shareCount);
            FHE.allowThis(_approvalVotes);
        } else {
            _rejectionVotes = FHE.add(_rejectionVotes, sh.shareCount);
            FHE.allowThis(_rejectionVotes);
        }
        emit VoteCast(msg.sender, approves);
    }

    function finalizeVote() external onlyOwner {
        require(voteOpen, "Not open");
        voteOpen = false;
        // Check if approval votes >= threshold% of total shares
        euint64 thresholdVotes = FHE.div(FHE.mul(_totalShares, _approvalThresholdBps), 10000);
        ebool approved = FHE.ge(_approvalVotes, thresholdVotes);
        buyoutApproved = FHE.isInitialized(approved);
        emit BuyoutResult(buyoutApproved);
    }

    function allowResults(address viewer) external onlyOwner {
        FHE.allow(_approvalVotes, viewer);
        FHE.allow(_rejectionVotes, viewer);
        FHE.allow(_totalShares, viewer);
    }
}
