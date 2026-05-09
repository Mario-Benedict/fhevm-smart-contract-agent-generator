// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAirlineRewardProgram
/// @notice Airline loyalty: encrypted miles earned, encrypted tier thresholds,
///         encrypted redemption values, private partner mile transfers.
contract PrivateAirlineRewardProgram is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MemberTier { Bronze, Silver, Gold, Platinum, Diamond }

    struct MemberAccount {
        euint32 totalMiles;            // encrypted total miles balance
        euint32 qualifyingMilesYTD;    // encrypted qualifying miles this year
        euint16 milesExpiringDays;     // encrypted days until expiry
        euint64 cashValueUSD;          // encrypted USD value of miles
        MemberTier tier;
        uint256 memberSince;
        uint256 lastActivityDate;
        bool active;
    }

    struct PartnerAirline {
        string airlineName;
        string iataCode;
        euint16 transferRatioBps;      // encrypted transfer ratio (miles per 10000 partner miles)
        bool active;
    }

    mapping(address => MemberAccount) private members;
    mapping(uint256 => PartnerAirline) private partners;
    mapping(address => bool) public isAirlineStaff;
    uint256 public partnerCount;
    euint32 private _totalMilesOutstanding;
    euint64 private _totalLiabilityUSD;
    euint32 private _tierThresholdSilver;
    euint32 private _tierThresholdGold;
    euint32 private _tierThresholdPlatinum;

    event MemberEnrolled(address indexed member);
    event MilesEarned(address indexed member, string flightCode);
    event MilesRedeemed(address indexed member);
    event TierUpgraded(address indexed member, MemberTier newTier);
    event PartnerTransfer(address indexed from, address indexed to, uint256 partnerId);

    modifier onlyStaff() {
        require(isAirlineStaff[msg.sender] || msg.sender == owner(), "Not staff");
        _;
    }

    constructor(
        externalEuint32 encSilver, bytes memory sPf,
        externalEuint32 encGold, bytes memory gPf,
        externalEuint32 encPlatinum, bytes memory pPf
    ) Ownable(msg.sender) {
        _tierThresholdSilver = FHE.fromExternal(encSilver, sPf);
        _tierThresholdGold = FHE.fromExternal(encGold, gPf);
        _tierThresholdPlatinum = FHE.fromExternal(encPlatinum, pPf);
        _totalMilesOutstanding = FHE.asEuint32(0);
        _totalLiabilityUSD = FHE.asEuint64(0);
        FHE.allowThis(_tierThresholdSilver);
        FHE.allowThis(_tierThresholdGold);
        FHE.allowThis(_tierThresholdPlatinum);
        FHE.allowThis(_totalMilesOutstanding);
        FHE.allowThis(_totalLiabilityUSD);
        isAirlineStaff[msg.sender] = true;
    }

    function addStaff(address s) external onlyOwner { isAirlineStaff[s] = true; }

    function enrollMember() external {
        require(!members[msg.sender].active, "Already enrolled");
        members[msg.sender] = MemberAccount({
            totalMiles: FHE.asEuint32(0), qualifyingMilesYTD: FHE.asEuint32(0),
            milesExpiringDays: FHE.asEuint16(365), cashValueUSD: FHE.asEuint64(0),
            tier: MemberTier.Bronze, memberSince: block.timestamp,
            lastActivityDate: block.timestamp, active: true
        });
        FHE.allowThis(members[msg.sender].totalMiles);
        FHE.allow(members[msg.sender].totalMiles, msg.sender);
        FHE.allowThis(members[msg.sender].qualifyingMilesYTD);
        FHE.allow(members[msg.sender].qualifyingMilesYTD, msg.sender);
        FHE.allowThis(members[msg.sender].milesExpiringDays);
        FHE.allowThis(members[msg.sender].cashValueUSD);
        FHE.allow(members[msg.sender].cashValueUSD, msg.sender);
        emit MemberEnrolled(msg.sender);
    }

    function awardMiles(
        address member, string calldata flightCode,
        externalEuint32 encMiles, bytes calldata mProof,
        externalEuint64 encCashValue, bytes calldata cvProof
    ) external onlyStaff {
        require(members[member].active, "Not member");
        euint32 miles = FHE.fromExternal(encMiles, mProof);
        euint64 cashVal = FHE.fromExternal(encCashValue, cvProof);
        members[member].totalMiles = FHE.add(members[member].totalMiles, miles);
        members[member].qualifyingMilesYTD = FHE.add(members[member].qualifyingMilesYTD, miles);
        members[member].cashValueUSD = FHE.add(members[member].cashValueUSD, cashVal);
        _totalMilesOutstanding = FHE.add(_totalMilesOutstanding, miles);
        _totalLiabilityUSD = FHE.add(_totalLiabilityUSD, cashVal);
        members[member].lastActivityDate = block.timestamp;
        FHE.allowThis(members[member].totalMiles);
        FHE.allow(members[member].totalMiles, member);
        FHE.allowThis(members[member].qualifyingMilesYTD);
        FHE.allowThis(members[member].cashValueUSD);
        FHE.allow(members[member].cashValueUSD, member);
        FHE.allowThis(_totalMilesOutstanding);
        FHE.allowThis(_totalLiabilityUSD);
        _checkTierUpgrade(member);
        emit MilesEarned(member, flightCode);
    }

    function _checkTierUpgrade(address member) internal {
        euint32 ytd = members[member].qualifyingMilesYTD;
        ebool isGold = FHE.ge(ytd, _tierThresholdGold);
        ebool isSilver = FHE.ge(ytd, _tierThresholdSilver);
        if (FHE.isInitialized(isGold) && members[member].tier < MemberTier.Gold) {
            members[member].tier = MemberTier.Gold;
            emit TierUpgraded(member, MemberTier.Gold);
        } else if (FHE.isInitialized(isSilver) && members[member].tier < MemberTier.Silver) {
            members[member].tier = MemberTier.Silver;
            emit TierUpgraded(member, MemberTier.Silver);
        }
    }

    function redeemMiles(externalEuint32 encMiles, bytes calldata proof) external nonReentrant {
        require(members[msg.sender].active, "Not member");
        euint32 miles = FHE.fromExternal(encMiles, proof);
        ebool hasSuf = FHE.le(miles, members[msg.sender].totalMiles);
        euint32 actual = FHE.select(hasSuf, miles, members[msg.sender].totalMiles);
        members[msg.sender].totalMiles = FHE.sub(members[msg.sender].totalMiles, actual);
        _totalMilesOutstanding = FHE.sub(_totalMilesOutstanding, actual);
        FHE.allowThis(members[msg.sender].totalMiles);
        FHE.allow(members[msg.sender].totalMiles, msg.sender);
        FHE.allowThis(_totalMilesOutstanding);
        FHE.allow(actual, msg.sender);
        emit MilesRedeemed(msg.sender);
    }

    function addPartner(
        string calldata airlineName, string calldata iataCode,
        externalEuint16 encRatio, bytes calldata proof
    ) external onlyOwner returns (uint256 id) {
        euint16 ratio = FHE.fromExternal(encRatio, proof);
        id = partnerCount++;
        partners[id] = PartnerAirline({ airlineName: airlineName, iataCode: iataCode,
            transferRatioBps: ratio, active: true });
        FHE.allowThis(partners[id].transferRatioBps);
    }

    function allowMemberDetails(address member, address viewer) external {
        require(isAirlineStaff[msg.sender] || msg.sender == member, "Unauthorized");
        FHE.allow(members[member].totalMiles, viewer);
        FHE.allow(members[member].cashValueUSD, viewer);
    }

    function allowProgramStats(address viewer) external onlyOwner {
        FHE.allow(_totalMilesOutstanding, viewer);
        FHE.allow(_totalLiabilityUSD, viewer);
    }
}
