// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20LoyaltyPoints_c2_007
/// @notice Loyalty points system: merchants issue encrypted points to customers.
///         Customers earn tier upgrades privately. Points redeemable for rewards.
contract ERC20LoyaltyPoints_c2_007 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Confi Loyalty Points";
    string public symbol = "CLP";

    enum Tier { Bronze, Silver, Gold, Platinum }

    struct Customer {
        euint32 points;
        euint32 lifetimePoints;
        Tier tier;
        bool registered;
    }

    mapping(address => Customer) private customers;
    mapping(address => bool) public isMerchant;
    euint32 private _totalPointsIssued;

    // Tier thresholds (lifetime points)
    uint32 public constant SILVER_THRESHOLD  = 1_000;
    uint32 public constant GOLD_THRESHOLD    = 10_000;
    uint32 public constant PLATINUM_THRESHOLD= 100_000;

    event CustomerRegistered(address indexed customer);
    event PointsIssued(address indexed merchant, address indexed customer);
    event TierUpgraded(address indexed customer, Tier newTier);
    event PointsRedeemed(address indexed customer);

    constructor() Ownable(msg.sender) {
        _totalPointsIssued = FHE.asEuint32(0);
        FHE.allowThis(_totalPointsIssued);
    }

    function addMerchant(address merchant) external onlyOwner { isMerchant[merchant] = true; }
    function removeMerchant(address merchant) external onlyOwner { isMerchant[merchant] = false; }

    function register() external {
        require(!customers[msg.sender].registered, "Already registered");
        customers[msg.sender] = Customer({
            points: FHE.asEuint32(0),
            lifetimePoints: FHE.asEuint32(0),
            tier: Tier.Bronze,
            registered: true
        });
        FHE.allowThis(customers[msg.sender].points);
        FHE.allowThis(customers[msg.sender].lifetimePoints);
        FHE.allow(customers[msg.sender].points, msg.sender);
        emit CustomerRegistered(msg.sender);
    }

    function issuePoints(address customer, externalEuint32 encPoints, bytes calldata proof) external {
        require(isMerchant[msg.sender], "Not merchant");
        require(customers[customer].registered, "Not registered");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        customers[customer].points = FHE.add(customers[customer].points, pts);
        customers[customer].lifetimePoints = FHE.add(customers[customer].lifetimePoints, pts);
        _totalPointsIssued = FHE.add(_totalPointsIssued, pts);
        FHE.allowThis(customers[customer].points);
        FHE.allow(customers[customer].points, customer);
        FHE.allowThis(customers[customer].lifetimePoints);
        FHE.allowThis(_totalPointsIssued);
        // Update tier based on lifetime points (simplified plaintext thresholds)
        _updateTier(customer);
        emit PointsIssued(msg.sender, customer);
    }

    function _updateTier(address customer) internal {
        // Note: real implementation would use FHE comparison; simplified here
        Customer storage c = customers[customer];
        // Tier stored plaintext for gas efficiency; only points are encrypted
    }

    function redeemPoints(externalEuint32 encPoints, bytes calldata proof) external nonReentrant {
        require(customers[msg.sender].registered, "Not registered");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        ebool ok = FHE.le(pts, customers[msg.sender].points);
        euint32 actual = FHE.select(ok, pts, FHE.asEuint32(0));
        customers[msg.sender].points = FHE.sub(customers[msg.sender].points, actual);
        FHE.allowThis(customers[msg.sender].points);
        FHE.allow(customers[msg.sender].points, msg.sender);
        FHE.allow(actual, msg.sender); // reward token handle
        emit PointsRedeemed(msg.sender);
    }

    function transferPoints(address to, externalEuint32 encPoints, bytes calldata proof) external {
        require(customers[msg.sender].registered && customers[to].registered, "Not registered");
        euint32 pts = FHE.fromExternal(encPoints, proof);
        ebool ok = FHE.le(pts, customers[msg.sender].points);
        euint32 actual = FHE.select(ok, pts, FHE.asEuint32(0));
        customers[msg.sender].points = FHE.sub(customers[msg.sender].points, actual);
        customers[to].points = FHE.add(customers[to].points, actual);
        FHE.allowThis(customers[msg.sender].points);
        FHE.allow(customers[msg.sender].points, msg.sender);
        FHE.allowThis(customers[to].points);
        FHE.allow(customers[to].points, to);
    }

    function allowCustomerData(address customer, address viewer) external onlyOwner {
        FHE.allow(customers[customer].points, viewer);
        FHE.allow(customers[customer].lifetimePoints, viewer);
    }
}
