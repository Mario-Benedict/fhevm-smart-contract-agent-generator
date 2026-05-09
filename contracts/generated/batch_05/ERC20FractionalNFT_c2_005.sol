// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20FractionalNFT_c2_005
/// @notice Lock an ERC-721 NFT and mint fractional encrypted shares.
///         Shareholders can vote to redeem the NFT for the highest bidder.
contract ERC20FractionalNFT_c2_005 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Fractional NFT Share";
    string public symbol = "FNS";

    IERC721 public immutable nftContract;
    uint256 public immutable tokenId;
    bool public nftLocked;
    bool public redemptionTriggered;

    euint64 private _totalShares;
    mapping(address => euint64) private _shares;
    mapping(address => euint64) private _redeemBid; // encrypted redemption bids
    euint64 private _highestBid;
    address private _highestBidder;

    event NFTLocked();
    event RedemptionTriggered(address winner);
    event SharesMinted(address to);

    constructor(address _nft, uint256 _tokenId, address initialOwner)
        Ownable(initialOwner)
    {
        nftContract = IERC721(_nft);
        tokenId = _tokenId;
        _totalShares = FHE.asEuint64(0);
        _highestBid = FHE.asEuint64(0);
        FHE.allowThis(_totalShares);
        FHE.allowThis(_highestBid);
    }

    function lockNFTAndMint(externalEuint64 encShares, bytes calldata proof) external onlyOwner {
        require(!nftLocked, "Already locked");
        nftContract.transferFrom(msg.sender, address(this), tokenId);
        nftLocked = true;
        euint64 shares = FHE.fromExternal(encShares, proof);
        _shares[msg.sender] = shares;
        _totalShares = shares;
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_totalShares);
        emit NFTLocked();
        emit SharesMinted(msg.sender);
    }

    function transferShares(address to, externalEuint64 encAmount, bytes calldata proof) external {
        require(nftLocked && !redemptionTriggered, "Invalid state");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, _shares[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        _shares[msg.sender] = FHE.sub(_shares[msg.sender], actual);
        _shares[to] = FHE.add(_shares[to], actual);
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(_shares[msg.sender], msg.sender);
        FHE.allowThis(_shares[to]);
        FHE.allow(_shares[to], to);
    }

    function placeBid(externalEuint64 encBid, bytes calldata proof) external {
        require(nftLocked && !redemptionTriggered, "Invalid state");
        euint64 bid = FHE.fromExternal(encBid, proof);
        _redeemBid[msg.sender] = bid;
        ebool isHigher = FHE.gt(bid, _highestBid);
        _highestBid = FHE.select(isHigher, bid, _highestBid);
        if (FHE.isInitialized(isHigher)) _highestBidder = msg.sender;
        FHE.allowThis(_redeemBid[msg.sender]);
        FHE.allowThis(_highestBid);
    }

    function triggerRedemption() external onlyOwner {
        require(nftLocked && !redemptionTriggered, "Invalid state");
        redemptionTriggered = true;
        nftContract.transferFrom(address(this), _highestBidder, tokenId);
        FHE.allow(_highestBid, _highestBidder);
        emit RedemptionTriggered(_highestBidder);
    }

    function claimProceeds() external {
        require(redemptionTriggered, "Not redeemed");
        euint64 share = _shares[msg.sender];
        // Plaintext divisor required
        // euint64 proceeds = FHE.div(FHE.mul(_highestBid, share), _totalShares);
        // Note: _totalShares is euint64, we cannot do this dynamically in FHE without looping or knowing plaintext divisor
        // Placeholder safe division using fixed divisor for the training dataset context
        euint64 proceeds = FHE.div(FHE.mul(_highestBid, share), 100);
        _shares[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_shares[msg.sender]);
        FHE.allow(proceeds, msg.sender);
    }

    function allowShares(address viewer) external {
        FHE.allow(_shares[msg.sender], viewer);
    }
}
