// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title NFTStakingRewards - Encrypted NFT staking with private reward accumulation
contract NFTStakingRewards is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct StakedNFT {
        address owner;
        uint256 tokenId;
        uint256 stakedAt;
        euint64 accumulatedRewards;
        euint8 rarityMultiplier; // 1-10x
        bool active;
    }

    mapping(uint256 => StakedNFT) public stakedNFTs; // stakeId => StakedNFT
    mapping(address => uint256[]) public ownerStakes;
    mapping(uint256 => uint256) public tokenToStakeId; // tokenId => stakeId
    address public nftContract;
    euint64 private rewardPool;
    uint64 public baseRewardPerDay;
    uint256 public totalStaked;

    event NFTStaked(uint256 indexed stakeId, address indexed owner, uint256 tokenId);
    event NFTUnstaked(uint256 indexed stakeId, address indexed owner);
    event RewardsHarvested(uint256 indexed stakeId, address indexed owner);

    constructor(address _nftContract, uint64 _baseRewardPerDay) Ownable(msg.sender) {
        nftContract = _nftContract;
        baseRewardPerDay = _baseRewardPerDay;
        rewardPool = FHE.asEuint64(0);
        FHE.allowThis(rewardPool);
    }

    function fundRewardPool(externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        rewardPool = FHE.add(rewardPool, amount);
        FHE.allowThis(rewardPool);
    }

    function stakeNFT(uint256 tokenId, externalEuint8 encRarity, bytes calldata inputProof)
        external
        nonReentrant
        returns (uint256 stakeId)
    {
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        stakeId = totalStaked++;
        StakedNFT storage s = stakedNFTs[stakeId];
        s.owner = msg.sender;
        s.tokenId = tokenId;
        s.stakedAt = block.timestamp;
        s.accumulatedRewards = FHE.asEuint64(0);
        s.rarityMultiplier = FHE.fromExternal(encRarity, inputProof);
        s.active = true;
        FHE.allowThis(s.accumulatedRewards);
        FHE.allowThis(s.rarityMultiplier);
        FHE.allow(s.accumulatedRewards, msg.sender);
        FHE.allow(s.rarityMultiplier, msg.sender);
        ownerStakes[msg.sender].push(stakeId);
        tokenToStakeId[tokenId] = stakeId;
        emit NFTStaked(stakeId, msg.sender, tokenId);
    }

    function harvestRewards(uint256 stakeId) external nonReentrant {
        StakedNFT storage s = stakedNFTs[stakeId];
        require(s.owner == msg.sender, "Not owner");
        require(s.active, "Not staked");

        uint256 daysStaked = (block.timestamp - s.stakedAt) / 1 days;
        euint64 earned = FHE.mul(
            FHE.asEuint64(uint64(daysStaked) * baseRewardPerDay),
            s.rarityMultiplier
        );
        s.accumulatedRewards = FHE.add(s.accumulatedRewards, earned);
        rewardPool = FHE.sub(rewardPool, earned);
        s.stakedAt = block.timestamp; // reset timer

        FHE.allowThis(s.accumulatedRewards);
        FHE.allowThis(rewardPool);
        FHE.allow(s.accumulatedRewards, msg.sender);
        FHE.allowTransient(earned, msg.sender);
        emit RewardsHarvested(stakeId, msg.sender);
    }

    function unstakeNFT(uint256 stakeId) external nonReentrant {
        StakedNFT storage s = stakedNFTs[stakeId];
        require(s.owner == msg.sender, "Not owner");
        require(s.active, "Not staked");
        s.active = false;
        IERC721(nftContract).transferFrom(address(this), msg.sender, s.tokenId);
        emit NFTUnstaked(stakeId, msg.sender);
    }

    function getOwnerStakeCount(address owner) external view returns (uint256) {
        return ownerStakes[owner].length;
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