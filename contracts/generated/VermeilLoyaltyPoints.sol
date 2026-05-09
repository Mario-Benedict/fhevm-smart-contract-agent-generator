// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VermeilLoyaltyPoints
/// @notice Confidential loyalty point token for retail programs with tier-based rewards
contract VermeilLoyaltyPoints is ZamaEthereumConfig, Ownable {
    string public constant name = "Vermeil Loyalty";
    string public constant symbol = "VRML";

    mapping(address => euint16) private _points;
    mapping(address => uint8) public tier; // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum

    uint16[4] public tierThresholds = [0, 500, 2000, 10000];
    uint8[4] public rewardMultipliers = [1, 2, 3, 5];

    mapping(address => bool) public authorizedMerchants;
    bool public redemptionOpen;

    event PointsAwarded(address indexed customer);
    event PointsRedeemed(address indexed customer);
    event TierUpgraded(address indexed customer, uint8 newTier);

    constructor() Ownable(msg.sender) {
        redemptionOpen = true;
    }

    function authorizeMerchant(address merchant, bool status) external onlyOwner {
        authorizedMerchants[merchant] = status;
    }

    function awardPoints(address customer, externalEuint16 encPoints, bytes calldata proof) external {
        require(authorizedMerchants[msg.sender], "Not authorized merchant");
        euint16 basePoints = FHE.fromExternal(encPoints, proof);
        euint16 bonus = FHE.mul(basePoints, uint16(rewardMultipliers[tier[customer]]));
        _points[customer] = FHE.add(_points[customer], bonus);
        FHE.allowThis(_points[customer]);
        FHE.allow(_points[customer], customer);
        emit PointsAwarded(customer);
    }

    function redeemPoints(externalEuint16 encPoints, bytes calldata proof) external {
        require(redemptionOpen, "Redemption closed");
        euint16 points = FHE.fromExternal(encPoints, proof);
        ebool sufficient = FHE.le(points, _points[msg.sender]);
        euint16 actualRedeem = FHE.select(sufficient, points, FHE.asEuint16(0));
        _points[msg.sender] = FHE.sub(_points[msg.sender], actualRedeem);
        FHE.allowThis(_points[msg.sender]);
        FHE.allow(_points[msg.sender], msg.sender);
        emit PointsRedeemed(msg.sender);
    }

    function upgradeTier(address customer, uint8 newTier) external onlyOwner {
        require(newTier <= 3, "Invalid tier");
        tier[customer] = newTier;
        emit TierUpgraded(customer, newTier);
    }

    function setRedemptionOpen(bool open) external onlyOwner {
        redemptionOpen = open;
    }

    function pointsOf(address customer) external view returns (euint16) {
        return _points[customer];
    }
}
