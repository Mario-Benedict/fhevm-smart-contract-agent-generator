// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ShieldedLoyaltyToken
/// @notice Loyalty token with encrypted balances and confidential tier system
contract ShieldedLoyaltyToken is ZamaEthereumConfig, Ownable {
    string public name = "Shielded Loyalty Token";
    string public symbol = "SLT";
    uint8 public decimals = 8;

    mapping(address => euint32) private _points;
    mapping(address => euint8) private _tier; // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum
    mapping(address => uint256) private _joinTime;
    mapping(address => uint256) private _lastActivity;

    uint32 private constant SILVER_THRESHOLD = 1000;
    uint32 private constant GOLD_THRESHOLD = 5000;
    uint32 private constant PLATINUM_THRESHOLD = 25000;

    uint32 public bronzeMultiplier = 100;  // 1x
    uint32 public silverMultiplier = 150;  // 1.5x
    uint32 public goldMultiplier = 200;    // 2x
    uint32 public platinumMultiplier = 300; // 3x

    address public rewardDistributor;

    event PointsEarned(address indexed user);
    event TierUpgraded(address indexed user);
    event PointsRedeemed(address indexed user);

    constructor() Ownable(msg.sender) {
        rewardDistributor = msg.sender;
    }

    modifier onlyDistributor() {
        require(msg.sender == rewardDistributor, "Not distributor");
        _;
    }

    function earnPoints(address user, externalEuint32 encBase, bytes calldata inputProof)
        external onlyDistributor
    {
        euint32 basePoints = FHE.fromExternal(encBase, inputProof);
        euint64 basePointsWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 basePointsExposure = FHE.sub(basePointsWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]

        // Apply multiplier based on tier
        euint8 userTier = _tier[user];
        euint32 multiplied = FHE.select(
            FHE.eq(userTier, FHE.asEuint8(3)),
            FHE.mul(basePoints, platinumMultiplier),
            FHE.select(
                FHE.eq(userTier, FHE.asEuint8(2)),
                FHE.mul(basePoints, goldMultiplier),
                FHE.select(
                    FHE.eq(userTier, FHE.asEuint8(1)),
                    FHE.mul(basePoints, silverMultiplier),
                    FHE.mul(basePoints, bronzeMultiplier)
                )
            )
        );
        euint32 finalPoints = FHE.div(multiplied, 100);

        _points[user] = FHE.add(_points[user], finalPoints);
        FHE.allowThis(_points[user]);
        FHE.allow(_points[user], user);

        if (_joinTime[user] == 0) _joinTime[user] = block.timestamp;
        _lastActivity[user] = block.timestamp;

        _updateTier(user);
        emit PointsEarned(user);
    }

    function _updateTier(address user) internal {
        euint32 pts = _points[user];
        euint8 newTier = FHE.select(
            FHE.ge(pts, FHE.asEuint32(25000)),
            FHE.asEuint8(3),
            FHE.select(
                FHE.ge(pts, FHE.asEuint32(5000)),
                FHE.asEuint8(2),
                FHE.select(
                    FHE.ge(pts, FHE.asEuint32(1000)),
                    FHE.asEuint8(1),
                    FHE.asEuint8(0)
                )
            )
        );
        _tier[user] = newTier;
        FHE.allowThis(_tier[user]);
        FHE.allow(_tier[user], user);

        emit TierUpgraded(user);
    }

    function redeemPoints(externalEuint32 encAmount, bytes calldata inputProof) external {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_points[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _points[msg.sender] = FHE.sub(_points[msg.sender], actual);
        FHE.allowThis(_points[msg.sender]);
        FHE.allow(_points[msg.sender], msg.sender);

        emit PointsRedeemed(msg.sender);
    }

    function transferPoints(address to, externalEuint32 encAmount, bytes calldata inputProof) external {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_points[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _points[msg.sender] = FHE.sub(_points[msg.sender], actual);
        _points[to] = FHE.add(_points[to], actual);

        FHE.allowThis(_points[msg.sender]);
        FHE.allow(_points[msg.sender], msg.sender);
        FHE.allowThis(_points[to]);
        FHE.allow(_points[to], to);
    }

    function pointsOf(address user) external view returns (euint32) { return _points[user]; }
    function tierOf(address user) external view returns (euint8) { return _tier[user]; }
    function setRewardDistributor(address d) external onlyOwner { rewardDistributor = d; }

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