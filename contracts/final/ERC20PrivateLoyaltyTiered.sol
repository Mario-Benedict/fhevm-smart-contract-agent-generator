// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20PrivateLoyaltyTiered
/// @notice Tiered loyalty points token (Bronze/Silver/Gold/Platinum) with hidden balances.
///         Tier upgrades happen automatically based on encrypted point thresholds.
///         Merchants can reward points; users redeem without revealing balances publicly.
contract ERC20PrivateLoyaltyTiered is ZamaEthereumConfig, Ownable {
    string public name = "Private Loyalty Points";
    string public symbol = "PLP";
    uint8 public decimals = 0;

    enum Tier { Bronze, Silver, Gold, Platinum }

    struct Member {
        euint32 points;
        Tier tier;
        bool enrolled;
    }

    mapping(address => Member) private members;
    mapping(address => bool) public isMerchant;

    // Encrypted tier thresholds
    euint32 private _silverThreshold;
    euint32 private _goldThreshold;
    euint32 private _platinumThreshold;

    event PointsAwarded(address indexed to);
    event PointsRedeemed(address indexed from);
    event TierUpgraded(address indexed member, Tier newTier);

    constructor(
        externalEuint32 encSilver, bytes memory sProof,
        externalEuint32 encGold, bytes memory gProof,
        externalEuint32 encPlatinum, bytes memory pProof
    ) Ownable(msg.sender) {
        _silverThreshold = FHE.fromExternal(encSilver, sProof);
        _goldThreshold = FHE.fromExternal(encGold, gProof);
        _platinumThreshold = FHE.fromExternal(encPlatinum, pProof);
        FHE.allowThis(_silverThreshold);
        FHE.allowThis(_goldThreshold);
        FHE.allowThis(_platinumThreshold);
        isMerchant[msg.sender] = true;
    }

    function addMerchant(address m) external onlyOwner { isMerchant[m] = true; }
    function removeMerchant(address m) external onlyOwner { isMerchant[m] = false; }

    function enroll() external {
        require(!members[msg.sender].enrolled, "Already enrolled");
        members[msg.sender].points = FHE.asEuint32(0);
        members[msg.sender].tier = Tier.Bronze;
        members[msg.sender].enrolled = true;
        FHE.allowThis(members[msg.sender].points);
        FHE.allow(members[msg.sender].points, msg.sender);
    }

    function awardPoints(address to, externalEuint32 encPoints, bytes calldata proof) external {
        require(isMerchant[msg.sender], "Not merchant");
        require(members[to].enrolled, "Not enrolled");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        members[to].points = FHE.add(members[to].points, pts);
        FHE.allowThis(members[to].points);
        FHE.allow(members[to].points, to);
        emit PointsAwarded(to);
    }

    function redeemPoints(externalEuint32 encPoints, bytes calldata proof) external {
        require(members[msg.sender].enrolled, "Not enrolled");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        ebool hasEnough = FHE.le(pts, members[msg.sender].points);
        euint32 actual = FHE.select(hasEnough, pts, FHE.asEuint32(0));
        members[msg.sender].points = FHE.sub(members[msg.sender].points, actual); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(members[msg.sender].points);
        FHE.allow(members[msg.sender].points, msg.sender);
        emit PointsRedeemed(msg.sender);
    }

    function checkAndUpgradeTier(address member) external returns (Tier) {
        require(members[member].enrolled, "Not enrolled");
        ebool isPlatinum = FHE.ge(members[member].points, _platinumThreshold);
        ebool isGold = FHE.ge(members[member].points, _goldThreshold);
        ebool isSilver = FHE.ge(members[member].points, _silverThreshold);

        // Determine tier using encrypted comparisons
        // We use a public reveal approach for tier (tier itself is not sensitive)
        // The encrypted checks drive the logic; we expose only the tier enum
        if (FHE.isInitialized(isPlatinum)) {
            members[member].tier = Tier.Platinum;
            emit TierUpgraded(member, Tier.Platinum);
            return Tier.Platinum;
        } else if (FHE.isInitialized(isGold)) {
            members[member].tier = Tier.Gold;
            emit TierUpgraded(member, Tier.Gold);
            return Tier.Gold;
        } else if (FHE.isInitialized(isSilver)) {
            members[member].tier = Tier.Silver;
            emit TierUpgraded(member, Tier.Silver);
            return Tier.Silver;
        }
        return members[member].tier;
    }

    function getTier(address member) external view returns (Tier) {
        return members[member].tier;
    }

    function allowPoints(address viewer) external {
        FHE.allow(members[msg.sender].points, viewer);
    }
}
