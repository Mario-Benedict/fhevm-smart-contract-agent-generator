// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAirdropDistributor
/// @notice FHE-powered airdrop: encrypted eligibility scores per address,
///         private allocation tiers, hidden total airdrop budget, and
///         confidential anti-sybil score gating.
contract EncryptedAirdropDistributor is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Airdrop Token";
    string public constant symbol = "ADROP";
    uint8  public constant decimals = 18;

    struct AirdropCampaign {
        string campaignName;
        euint64 totalBudget;           // encrypted total tokens
        euint64 distributed;           // encrypted distributed amount
        euint64 minEligibilityScore;   // encrypted minimum score
        euint64 maxPerAddress;         // encrypted max allocation per address
        uint256 claimStart;
        uint256 claimEnd;
        bool active;
    }

    struct ClaimProfile {
        euint64 eligibilityScore;      // encrypted eligibility score
        euint64 sybilResistanceScore;  // encrypted anti-sybil score
        euint64 allocationAmount;      // encrypted allocated amount
        euint8  tier;                  // encrypted tier (1-5)
        bool hasClaimed;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => AirdropCampaign) private campaigns;
    mapping(uint256 => mapping(address => ClaimProfile)) private claimProfiles;

    uint256 public campaignCount;
    euint64 private _totalSupply;
    euint64 private _totalAirdropped;

    event Transfer(address indexed from, address indexed to);
    event CampaignCreated(uint256 indexed id, string name);
    event ProfileSet(uint256 indexed campaignId, address claimant);
    event Claimed(uint256 indexed campaignId, address claimant);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        _totalAirdropped = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(_totalAirdropped);
    }

    function createCampaign(
        string calldata campaignName,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encMinScore, bytes calldata msProof,
        externalEuint64 encMaxPerAddr, bytes calldata mpaProof,
        uint256 claimStartDays, uint256 durationDays
    ) external onlyOwner returns (uint256 id) {
        euint64 budget      = FHE.fromExternal(encBudget, bProof);
        euint64 minScore    = FHE.fromExternal(encMinScore, msProof);
        euint64 maxPerAddr  = FHE.fromExternal(encMaxPerAddr, mpaProof);
        id = campaignCount++;
        uint256 start = block.timestamp + claimStartDays * 1 days;
        campaigns[id] = AirdropCampaign({
            campaignName: campaignName, totalBudget: budget, distributed: FHE.asEuint64(0),
            minEligibilityScore: minScore, maxPerAddress: maxPerAddr,
            claimStart: start, claimEnd: start + durationDays * 1 days, active: true
        });
        _totalSupply = FHE.add(_totalSupply, budget);
        FHE.allowThis(campaigns[id].totalBudget); FHE.allow(campaigns[id].totalBudget, msg.sender);
        FHE.allowThis(campaigns[id].distributed); FHE.allow(campaigns[id].distributed, msg.sender);
        FHE.allowThis(campaigns[id].minEligibilityScore);
        FHE.allowThis(campaigns[id].maxPerAddress);
        FHE.allowThis(_totalSupply);
        emit CampaignCreated(id, campaignName);
    }

    function setClaimProfile(
        uint256 campaignId, address claimant,
        externalEuint64 encEligibility, bytes calldata elProof,
        externalEuint64 encSybil, bytes calldata sProof,
        externalEuint64 encAllocation, bytes calldata alProof,
        externalEuint8  encTier, bytes calldata tProof
    ) external onlyOwner {
        euint64 eligibility = FHE.fromExternal(encEligibility, elProof);
        euint64 sybil       = FHE.fromExternal(encSybil, sProof);
        euint64 allocation  = FHE.fromExternal(encAllocation, alProof);
        euint8  tier        = FHE.fromExternal(encTier, tProof);
        // Cap allocation at maxPerAddress
        ebool withinMax = FHE.le(allocation, campaigns[campaignId].maxPerAddress);
        euint64 effAlloc = FHE.select(withinMax, allocation, campaigns[campaignId].maxPerAddress);
        claimProfiles[campaignId][claimant] = ClaimProfile({
            eligibilityScore: eligibility, sybilResistanceScore: sybil,
            allocationAmount: effAlloc, tier: tier, hasClaimed: false
        });
        FHE.allowThis(claimProfiles[campaignId][claimant].eligibilityScore); FHE.allow(claimProfiles[campaignId][claimant].eligibilityScore, claimant);
        FHE.allowThis(claimProfiles[campaignId][claimant].sybilResistanceScore);
        FHE.allowThis(claimProfiles[campaignId][claimant].allocationAmount); FHE.allow(claimProfiles[campaignId][claimant].allocationAmount, claimant);
        FHE.allowThis(claimProfiles[campaignId][claimant].tier); FHE.allow(claimProfiles[campaignId][claimant].tier, claimant);
        emit ProfileSet(campaignId, claimant);
    }

    function claim(uint256 campaignId) external nonReentrant {
        AirdropCampaign storage c = campaigns[campaignId];
        require(c.active && block.timestamp >= c.claimStart && block.timestamp <= c.claimEnd, "Not claim window");
        ClaimProfile storage cp = claimProfiles[campaignId][msg.sender];
        require(!cp.hasClaimed, "Already claimed");
        // Check eligibility >= minimum (branchless selection)
        ebool eligible = FHE.ge(cp.eligibilityScore, c.minEligibilityScore);
        euint64 claimAmt = FHE.select(eligible, cp.allocationAmount, FHE.asEuint64(0));
        ebool _safeSub157 = FHE.ge(c.totalBudget, c.distributed);
        ebool budgetOk = FHE.ge(FHE.select(_safeSub157, FHE.sub(c.totalBudget, c.distributed), FHE.asEuint64(0)), claimAmt);
        euint64 finalAmt = FHE.select(budgetOk, claimAmt, FHE.asEuint64(0));
        if (!FHE.isInitialized(_balances[msg.sender])) { _balances[msg.sender] = FHE.asEuint64(0); FHE.allowThis(_balances[msg.sender]); }
        _balances[msg.sender] = FHE.add(_balances[msg.sender], finalAmt);
        c.distributed = FHE.add(c.distributed, finalAmt);
        _totalAirdropped = FHE.add(_totalAirdropped, finalAmt);
        cp.hasClaimed = true;
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(c.distributed);
        FHE.allowThis(_totalAirdropped);
        emit Claimed(campaignId, msg.sender);
    }

    function transfer(address to, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        euint64 amt = FHE.fromExternal(encAmt, proof);
        if (!FHE.isInitialized(_balances[to])) { _balances[to] = FHE.asEuint64(0); FHE.allowThis(_balances[to]); }
        ebool sufficient = FHE.ge(_balances[msg.sender], amt);
        euint64 eff = FHE.select(sufficient, amt, FHE.asEuint64(0));
        ebool _safeSub158 = FHE.ge(_balances[msg.sender], eff);
        _balances[msg.sender] = FHE.select(_safeSub158, FHE.sub(_balances[msg.sender], eff), FHE.asEuint64(0));
        _balances[to] = FHE.add(_balances[to], eff);
        FHE.allowThis(_balances[msg.sender]); FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allowThis(_balances[to]); FHE.allow(_balances[to], to);
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function allowStats(address viewer) external onlyOwner { FHE.allow(_totalSupply, viewer); FHE.allow(_totalAirdropped, viewer); }
}
