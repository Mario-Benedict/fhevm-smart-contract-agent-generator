// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20EncryptedEmployeeEquityPlan
/// @notice Employee equity compensation plan with encrypted vesting schedules,
///         strike prices, and grant sizes. Supports cliff vesting, acceleration,
///         and encrypted tax withholding calculations.
contract ERC20EncryptedEmployeeEquityPlan is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum GrantType { ISO, NSO, RSU, ESPP, PerformanceShare }
    enum VestingSchedule { Monthly, Quarterly, Annual, CliffOnly, Milestone }

    struct EquityGrant {
        address grantee;
        GrantType grantType;
        VestingSchedule vestingSchedule;
        euint64 totalSharesGranted;     // encrypted grant size
        euint64 sharesVested;           // encrypted vested shares
        euint64 sharesExercised;        // encrypted exercised shares
        euint64 strikePriceCentsUSD;    // encrypted exercise price
        euint64 currentFMVCentsUSD;     // encrypted fair market value
        euint32 vestingPeriodMonths;    // encrypted vesting period
        euint32 cliffMonths;            // encrypted cliff period
        euint32 accelerationTriggerBps; // encrypted acceleration condition
        euint64 taxWithholdingCents;    // encrypted tax withholding
        bool active;
        uint256 grantDate;
        uint256 expiryDate;
    }

    struct ExerciseRecord {
        uint256 grantId;
        euint64 sharesExercised;
        euint64 proceedsCents;        // encrypted exercise proceeds
        euint64 taxableGainCents;     // encrypted taxable gain
        uint256 exerciseDate;
    }

    mapping(uint256 => EquityGrant) private grants;
    mapping(address => uint256[]) private granteeGrants;
    mapping(uint256 => ExerciseRecord[]) private exerciseHistory;
    mapping(address => bool) public isEquityAdmin;
    mapping(address => bool) public isBoardApprover;

    uint256 public grantCount;
    euint64 private _totalSharesOutstanding;
    euint64 private _totalExerciseProceeds;
    euint64 private _poolRemainingShares;

    event GrantCreated(uint256 indexed grantId, address grantee, GrantType grantType);
    event SharesVested(uint256 indexed grantId, address grantee);
    event GrantExercised(uint256 indexed grantId, address grantee);
    event GrantCancelled(uint256 indexed grantId);
    event GrantAccelerated(uint256 indexed grantId);

    modifier onlyEquityAdmin() {
        require(isEquityAdmin[msg.sender] || msg.sender == owner(), "Not equity admin");
        _;
    }

    constructor(externalEuint64 encPoolSize, bytes memory poolProof) Ownable(msg.sender) {
        _poolRemainingShares = FHE.fromExternal(encPoolSize, poolProof);
        _totalSharesOutstanding = FHE.asEuint64(0);
        _totalExerciseProceeds = FHE.asEuint64(0);
        FHE.allowThis(_poolRemainingShares);
        FHE.allowThis(_totalSharesOutstanding);
        FHE.allowThis(_totalExerciseProceeds);
        isEquityAdmin[msg.sender] = true;
        isBoardApprover[msg.sender] = true;
    }

    function addEquityAdmin(address admin) external onlyOwner { isEquityAdmin[admin] = true; }
    function addBoardApprover(address board) external onlyOwner { isBoardApprover[board] = true; }

    function createGrant(
        address grantee,
        GrantType grantType,
        VestingSchedule vestSched,
        externalEuint64 encShares, bytes calldata sharesProof,
        externalEuint64 encStrikePrice, bytes calldata strikeProof,
        externalEuint32 encVestingPeriod, bytes calldata vestProof,
        externalEuint32 encCliff, bytes calldata cliffProof,
        uint256 expiryDate
    ) external onlyEquityAdmin returns (uint256 grantId) {
        euint64 shares = FHE.fromExternal(encShares, sharesProof);
        euint64 strikePrice = FHE.fromExternal(encStrikePrice, strikeProof);
        euint32 vestPeriod = FHE.fromExternal(encVestingPeriod, vestProof);
        euint32 cliff = FHE.fromExternal(encCliff, cliffProof);

        // Check pool availability
        ebool poolOk = FHE.le(shares, _poolRemainingShares);
        euint64 actualShares = FHE.select(poolOk, shares, _poolRemainingShares);

        grantId = grantCount++;
        EquityGrant storage g = grants[grantId];
        g.grantee = grantee;
        g.grantType = grantType;
        g.vestingSchedule = vestSched;
        g.totalSharesGranted = actualShares;
        g.sharesVested = FHE.asEuint64(0);
        g.sharesExercised = FHE.asEuint64(0);
        g.strikePriceCentsUSD = strikePrice;
        g.currentFMVCentsUSD = strikePrice; // initial FMV = strike
        g.vestingPeriodMonths = vestPeriod;
        g.cliffMonths = cliff;
        g.accelerationTriggerBps = FHE.asEuint32(0);
        g.taxWithholdingCents = FHE.asEuint64(0);
        g.active = true;
        g.grantDate = block.timestamp;
        g.expiryDate = expiryDate;

        _poolRemainingShares = FHE.sub(_poolRemainingShares, actualShares);
        _totalSharesOutstanding = FHE.add(_totalSharesOutstanding, actualShares);

        granteeGrants[grantee].push(grantId);

        FHE.allowThis(g.totalSharesGranted); FHE.allow(g.totalSharesGranted, grantee);
        FHE.allowThis(g.sharesVested); FHE.allow(g.sharesVested, grantee);
        FHE.allowThis(g.sharesExercised); FHE.allow(g.sharesExercised, grantee);
        FHE.allowThis(g.strikePriceCentsUSD); FHE.allow(g.strikePriceCentsUSD, grantee);
        FHE.allowThis(g.currentFMVCentsUSD); FHE.allow(g.currentFMVCentsUSD, grantee);
        FHE.allowThis(g.vestingPeriodMonths); FHE.allow(g.vestingPeriodMonths, grantee);
        FHE.allowThis(g.cliffMonths); FHE.allow(g.cliffMonths, grantee);
        FHE.allowThis(g.accelerationTriggerBps);
        FHE.allowThis(g.taxWithholdingCents); FHE.allow(g.taxWithholdingCents, grantee);
        FHE.allowThis(_poolRemainingShares); FHE.allowThis(_totalSharesOutstanding);

        emit GrantCreated(grantId, grantee, grantType);
    }

    function vestShares(
        uint256 grantId,
        externalEuint64 encVestingAmount, bytes calldata proof
    ) external onlyEquityAdmin {
        EquityGrant storage g = grants[grantId];
        require(g.active, "Grant not active");
        euint64 vestAmount = FHE.fromExternal(encVestingAmount, proof);
        euint64 remaining = FHE.sub(g.totalSharesGranted, g.sharesVested);
        ebool fits = FHE.le(vestAmount, remaining);
        euint64 actual = FHE.select(fits, vestAmount, remaining);
        g.sharesVested = FHE.add(g.sharesVested, actual);
        FHE.allowThis(g.sharesVested); FHE.allow(g.sharesVested, g.grantee);
        emit SharesVested(grantId, g.grantee);
    }

    function exerciseGrant(
        uint256 grantId,
        externalEuint64 encSharesToExercise, bytes calldata sharesProof
    ) external nonReentrant {
        EquityGrant storage g = grants[grantId];
        require(g.grantee == msg.sender, "Not grantee");
        require(g.active && block.timestamp < g.expiryDate, "Grant inactive/expired");

        euint64 exerciseShares = FHE.fromExternal(encSharesToExercise, sharesProof);
        euint64 exercisable = FHE.sub(g.sharesVested, g.sharesExercised);
        ebool ok = FHE.le(exerciseShares, exercisable);
        euint64 actual = FHE.select(ok, exerciseShares, exercisable);

        euint64 proceeds = FHE.mul(actual, g.strikePriceCentsUSD); // [arithmetic_overflow_underflow]
        euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 gain = FHE.mul(actual, FHE.sub(g.currentFMVCentsUSD, g.strikePriceCentsUSD));
        euint64 taxWithholding = FHE.div(FHE.mul(gain, 2400), 10000); // ~24% bracket

        g.sharesExercised = FHE.add(g.sharesExercised, actual);
        g.taxWithholdingCents = FHE.add(g.taxWithholdingCents, taxWithholding);
        _totalExerciseProceeds = FHE.add(_totalExerciseProceeds, proceeds);

        uint256 exIdx = exerciseHistory[grantId].length;
        exerciseHistory[grantId].push(ExerciseRecord({
            grantId: grantId,
            sharesExercised: actual,
            proceedsCents: proceeds,
            taxableGainCents: gain,
            exerciseDate: block.timestamp
        }));

        FHE.allowThis(g.sharesExercised); FHE.allow(g.sharesExercised, msg.sender);
        FHE.allowThis(g.taxWithholdingCents); FHE.allow(g.taxWithholdingCents, msg.sender);
        FHE.allow(proceeds, msg.sender); FHE.allow(gain, msg.sender);
        FHE.allowThis(exerciseHistory[grantId][exIdx].sharesExercised);
        FHE.allowThis(exerciseHistory[grantId][exIdx].proceedsCents);
        FHE.allowThis(exerciseHistory[grantId][exIdx].taxableGainCents);
        FHE.allowThis(_totalExerciseProceeds);

        emit GrantExercised(grantId, msg.sender);
    }

    function updateFMV(uint256 grantId, externalEuint64 encFMV, bytes calldata proof) external onlyEquityAdmin {
        euint64 fmv = FHE.fromExternal(encFMV, proof);
        grants[grantId].currentFMVCentsUSD = fmv;
        FHE.allowThis(grants[grantId].currentFMVCentsUSD);
        FHE.allow(grants[grantId].currentFMVCentsUSD, grants[grantId].grantee);
    }

    function cancelGrant(uint256 grantId) external onlyEquityAdmin {
        EquityGrant storage g = grants[grantId];
        require(g.active, "Not active");
        euint64 unvested = FHE.sub(g.totalSharesGranted, g.sharesVested);
        _poolRemainingShares = FHE.add(_poolRemainingShares, unvested);
        _totalSharesOutstanding = FHE.sub(_totalSharesOutstanding, unvested);
        g.active = false;
        FHE.allowThis(_poolRemainingShares); FHE.allowThis(_totalSharesOutstanding);
        emit GrantCancelled(grantId);
    }

    function allowEquityStats(address viewer) external onlyOwner {
        FHE.allow(_totalSharesOutstanding, viewer);
        FHE.allow(_totalExerciseProceeds, viewer);
        FHE.allow(_poolRemainingShares, viewer);
    }

    function getGrantCount(address grantee) external view returns (uint256) {
        return granteeGrants[grantee].length;
    }
}
