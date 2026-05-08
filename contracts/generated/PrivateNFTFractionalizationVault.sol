// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateNFTFractionalizationVault
/// @notice Fractional NFT vault with encrypted share prices, confidential
///         buyout bids, and private revenue distributions from NFT yield.
///         Supports encrypted governance votes for buyout approval.
contract PrivateNFTFractionalizationVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {

    struct NFTVault {
        uint256 nftTokenId;
        address nftContract;
        euint64 totalShares;          // encrypted total fractional shares
        euint64 initialSharePrice;    // encrypted initial price per share
        euint64 currentNAVPerShare;   // encrypted current net asset value per share
        euint64 totalRevenue;         // encrypted accumulated NFT yield/royalties
        euint64 buyoutThresholdBps;   // encrypted % of shares needed to trigger buyout vote
        euint64 buyoutBid;            // encrypted current buyout bid
        address buyoutBidder;
        bool buyoutActive;
        bool active;
    }

    struct ShareHolder {
        euint64 sharesHeld;
        euint64 unclaimedRevenue;
        euint64 votingPowerBps;
        bool votedForBuyout;
    }

    struct BuyoutVote {
        euint64 totalVotesFor;    // encrypted votes in favour
        euint64 totalVotesAgainst;
        uint256 voteDeadline;
        bool executed;
    }

    mapping(uint256 => NFTVault) private vaults;
    mapping(uint256 => mapping(address => ShareHolder)) private shareholders;
    mapping(uint256 => BuyoutVote) private buyoutVotes;
    mapping(address => bool) public isVaultManager;

    uint256 public vaultCount;
    euint64 private _totalLockedValueUSD;

    event VaultCreated(uint256 indexed vaultId, uint256 nftTokenId);
    event SharesMinted(uint256 indexed vaultId, address indexed to);
    event RevenueDistributed(uint256 indexed vaultId);
    event BuyoutBidPlaced(uint256 indexed vaultId, address bidder);
    event BuyoutVoteStarted(uint256 indexed vaultId, uint256 deadline);
    event BuyoutExecuted(uint256 indexed vaultId, address bidder);
    event RevenueClaimed(uint256 indexed vaultId, address indexed holder);

    constructor() Ownable(msg.sender) {
        _totalLockedValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalLockedValueUSD);
        isVaultManager[msg.sender] = true;
    }

    modifier onlyVaultManager() { require(isVaultManager[msg.sender], "Not vault manager"); _; }

    function createVault(
        uint256 nftTokenId,
        address nftContract,
        externalEuint64 encTotalShares, bytes calldata tsProof,
        externalEuint64 encSharePrice, bytes calldata spProof,
        externalEuint64 encBuyoutThreshold, bytes calldata btProof
    ) external onlyVaultManager returns (uint256 vaultId) {
        vaultId = vaultCount++;
        NFTVault storage v = vaults[vaultId];
        v.nftTokenId = nftTokenId;
        v.nftContract = nftContract;
        v.totalShares = FHE.fromExternal(encTotalShares, tsProof);
        v.initialSharePrice = FHE.fromExternal(encSharePrice, spProof);
        v.currentNAVPerShare = v.initialSharePrice;
        v.totalRevenue = FHE.asEuint64(0);
        v.buyoutThresholdBps = FHE.fromExternal(encBuyoutThreshold, btProof);
        v.buyoutBid = FHE.asEuint64(0);
        v.active = true;
        FHE.allowThis(v.totalShares);
        FHE.allowThis(v.initialSharePrice);
        FHE.allowThis(v.currentNAVPerShare);
        FHE.allowThis(v.totalRevenue);
        FHE.allowThis(v.buyoutThresholdBps);
        FHE.allowThis(v.buyoutBid);
        emit VaultCreated(vaultId, nftTokenId);
    }

    function mintShares(
        uint256 vaultId,
        address to,
        externalEuint64 encShares, bytes calldata sProof
    ) external onlyVaultManager {
        NFTVault storage v = vaults[vaultId];
        require(v.active, "Vault not active");
        euint64 shares = FHE.fromExternal(encShares, sProof);
        ShareHolder storage sh = shareholders[vaultId][to];
        sh.sharesHeld = FHE.add(sh.sharesHeld, shares);
        sh.unclaimedRevenue = FHE.add(sh.unclaimedRevenue, FHE.asEuint64(0));
        // Voting power = shares / totalShares * 10000
        euint64 totalShares = v.totalShares;
        sh.votingPowerBps = FHE.div(FHE.mul(sh.sharesHeld, 10000), totalShares);
        FHE.allowThis(sh.sharesHeld);
        FHE.allow(sh.sharesHeld, to);
        FHE.allowThis(sh.unclaimedRevenue);
        FHE.allow(sh.unclaimedRevenue, to);
        FHE.allowThis(sh.votingPowerBps);
        FHE.allow(sh.votingPowerBps, to);
        emit SharesMinted(vaultId, to);
    }

    function depositRevenue(
        uint256 vaultId,
        externalEuint64 encRevenue, bytes calldata rProof
    ) external onlyVaultManager {
        NFTVault storage v = vaults[vaultId];
        require(v.active, "Vault not active");
        euint64 revenue = FHE.fromExternal(encRevenue, rProof);
        v.totalRevenue = FHE.add(v.totalRevenue, revenue);
        // Update NAV per share
        v.currentNAVPerShare = FHE.add(v.currentNAVPerShare,
            FHE.div(revenue, v.totalShares));
        _totalLockedValueUSD = FHE.add(_totalLockedValueUSD, revenue);
        FHE.allowThis(v.totalRevenue);
        FHE.allowThis(v.currentNAVPerShare);
        FHE.allowThis(_totalLockedValueUSD);
        emit RevenueDistributed(vaultId);
    }

    function claimRevenue(uint256 vaultId) external nonReentrant whenNotPaused {
        ShareHolder storage sh = shareholders[vaultId][msg.sender];
        require(FHE.decrypt(FHE.gt(sh.sharesHeld, FHE.asEuint64(0))), "No shares");
        NFTVault storage v = vaults[vaultId];
        // Pro-rata revenue = (shares / totalShares) * totalRevenue
        euint64 proRataRevenue = FHE.div(FHE.mul(sh.sharesHeld, v.totalRevenue), v.totalShares);
        euint64 unclaimed = FHE.sub(proRataRevenue, sh.unclaimedRevenue);
        sh.unclaimedRevenue = proRataRevenue;
        FHE.allowThis(sh.unclaimedRevenue);
        FHE.allow(sh.unclaimedRevenue, msg.sender);
        FHE.allowTransient(unclaimed, msg.sender);
        emit RevenueClaimed(vaultId, msg.sender);
    }

    function placeBuyoutBid(
        uint256 vaultId,
        externalEuint64 encBid, bytes calldata bProof
    ) external nonReentrant whenNotPaused {
        NFTVault storage v = vaults[vaultId];
        require(v.active && !v.buyoutActive, "Invalid state");
        euint64 bid = FHE.fromExternal(encBid, bProof);
        // Must exceed current NAV total
        euint64 totalNAV = FHE.mul(v.currentNAVPerShare, v.totalShares);
        ebool bidAboveNAV = FHE.gt(bid, totalNAV);
        euint64 validBid = FHE.select(bidAboveNAV, bid, totalNAV);
        v.buyoutBid = validBid;
        v.buyoutBidder = msg.sender;
        v.buyoutActive = true;
        FHE.allowThis(v.buyoutBid);
        FHE.allow(v.buyoutBid, msg.sender);
        buyoutVotes[vaultId].totalVotesFor = FHE.asEuint64(0);
        buyoutVotes[vaultId].totalVotesAgainst = FHE.asEuint64(0);
        buyoutVotes[vaultId].voteDeadline = block.timestamp + 7 days;
        FHE.allowThis(buyoutVotes[vaultId].totalVotesFor);
        FHE.allowThis(buyoutVotes[vaultId].totalVotesAgainst);
        emit BuyoutBidPlaced(vaultId, msg.sender);
        emit BuyoutVoteStarted(vaultId, block.timestamp + 7 days);
    }

    function voteOnBuyout(uint256 vaultId, bool support) external {
        BuyoutVote storage bv = buyoutVotes[vaultId];
        ShareHolder storage sh = shareholders[vaultId][msg.sender];
        require(!sh.votedForBuyout, "Already voted");
        require(block.timestamp < bv.voteDeadline, "Vote closed");
        sh.votedForBuyout = true;
        if (support) {
            bv.totalVotesFor = FHE.add(bv.totalVotesFor, sh.votingPowerBps);
            FHE.allowThis(bv.totalVotesFor);
        } else {
            bv.totalVotesAgainst = FHE.add(bv.totalVotesAgainst, sh.votingPowerBps);
            FHE.allowThis(bv.totalVotesAgainst);
        }
    }

    function executeBuyout(uint256 vaultId) external onlyVaultManager {
        BuyoutVote storage bv = buyoutVotes[vaultId];
        NFTVault storage v = vaults[vaultId];
        require(block.timestamp >= bv.voteDeadline && !bv.executed, "Cannot execute");
        ebool approved = FHE.gt(bv.totalVotesFor, bv.totalVotesAgainst);
        if (FHE.decrypt(approved)) {
            bv.executed = true;
            v.active = false;
            emit BuyoutExecuted(vaultId, v.buyoutBidder);
        }
    }

    function addVaultManager(address vm) external onlyOwner { isVaultManager[vm] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
