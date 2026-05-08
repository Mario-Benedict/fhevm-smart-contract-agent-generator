// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateHedgeFundSideLetterTerms
/// @notice Encrypted hedge fund side letter management: hidden preferred MFN terms,
///         confidential fee concessions per investor class, private redemption priority
///         arrangements, and encrypted capacity reservation fee schedules.
contract PrivateHedgeFundSideLetterTerms is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum InvestorClass { Institutional, FamilyOffice, SWF, Endowment, FoundingLP, RetailAccredited }
    enum FeeArrangement { StandardFees, ReducedMgmt, ReducedPerf, MFNBestTerms, ZeroFees }

    struct SideLetter {
        address investor;
        address fundManager;
        InvestorClass investorClass;
        FeeArrangement feeArrangement;
        euint64 committedCapitalUSD;   // encrypted commitment
        euint16 negotiatedMgmtFeeBps;  // encrypted mgmt fee concession
        euint16 negotiatedPerfFeeBps;  // encrypted perf fee concession
        euint64 capacityReservationFeeUSD; // encrypted capacity fee
        euint32 lockupDays;            // encrypted lockup period
        euint16 redemptionPriorityScore; // encrypted redemption priority
        euint64 highWaterMarkUSD;      // encrypted HWM
        uint256 signedAt;
        uint256 termEndDate;
        bool active;
    }

    mapping(uint256 => SideLetter) private sideLetters;
    mapping(address => bool) public isFundCompliance;

    uint256 public sideLetterCount;
    euint64 private _totalCommittedCapitalUSD;

    event SideLetterSigned(uint256 indexed id, InvestorClass investorClass, FeeArrangement feeArrangement);
    event SideLetterTerminated(uint256 indexed id);

    modifier onlyFundCompliance() {
        require(isFundCompliance[msg.sender] || msg.sender == owner(), "Not fund compliance");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCommittedCapitalUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCommittedCapitalUSD);
        isFundCompliance[msg.sender] = true;
    }

    function addFundCompliance(address fc) external onlyOwner { isFundCompliance[fc] = true; }

    function signSideLetter(
        address investor, InvestorClass investorClass, FeeArrangement feeArrangement,
        externalEuint64 encCommitment, bytes calldata comProof,
        externalEuint16 encMgmtFee, bytes calldata mfProof,
        externalEuint16 encPerfFee, bytes calldata pfProof,
        externalEuint64 encCapacityFee, bytes calldata cfProof,
        externalEuint32 encLockup, bytes calldata lProof,
        externalEuint16 encRedemptionPriority, bytes calldata rpProof,
        uint256 termDays
    ) external onlyFundCompliance returns (uint256 id) {
        euint64 commitment = FHE.fromExternal(encCommitment, comProof);
        euint16 mgmtFee = FHE.fromExternal(encMgmtFee, mfProof);
        euint16 perfFee = FHE.fromExternal(encPerfFee, pfProof);
        euint64 capacityFee = FHE.fromExternal(encCapacityFee, cfProof);
        euint32 lockup = FHE.fromExternal(encLockup, lProof);
        euint16 redemptionPriority = FHE.fromExternal(encRedemptionPriority, rpProof);
        id = sideLetterCount++;
        sideLetters[id] = SideLetter({
            investor: investor, fundManager: msg.sender, investorClass: investorClass,
            feeArrangement: feeArrangement, committedCapitalUSD: commitment,
            negotiatedMgmtFeeBps: mgmtFee, negotiatedPerfFeeBps: perfFee,
            capacityReservationFeeUSD: capacityFee, lockupDays: lockup,
            redemptionPriorityScore: redemptionPriority, highWaterMarkUSD: FHE.asEuint64(0),
            signedAt: block.timestamp, termEndDate: block.timestamp + termDays * 1 days, active: true
        });
        _totalCommittedCapitalUSD = FHE.add(_totalCommittedCapitalUSD, commitment);
        FHE.allowThis(sideLetters[id].committedCapitalUSD); FHE.allow(sideLetters[id].committedCapitalUSD, investor); FHE.allow(sideLetters[id].committedCapitalUSD, msg.sender);
        FHE.allowThis(sideLetters[id].negotiatedMgmtFeeBps); FHE.allow(sideLetters[id].negotiatedMgmtFeeBps, investor);
        FHE.allowThis(sideLetters[id].negotiatedPerfFeeBps); FHE.allow(sideLetters[id].negotiatedPerfFeeBps, investor);
        FHE.allowThis(sideLetters[id].capacityReservationFeeUSD); FHE.allow(sideLetters[id].capacityReservationFeeUSD, investor);
        FHE.allowThis(sideLetters[id].lockupDays); FHE.allow(sideLetters[id].lockupDays, investor);
        FHE.allowThis(sideLetters[id].redemptionPriorityScore);
        FHE.allowThis(sideLetters[id].highWaterMarkUSD); FHE.allow(sideLetters[id].highWaterMarkUSD, investor);
        FHE.allowThis(_totalCommittedCapitalUSD);
        emit SideLetterSigned(id, investorClass, feeArrangement);
    }

    function updateHighWaterMark(
        uint256 sideLetterIdx,
        externalEuint64 encHWM, bytes calldata proof
    ) external onlyFundCompliance {
        sideLetters[sideLetterIdx].highWaterMarkUSD = FHE.fromExternal(encHWM, proof);
        FHE.allowThis(sideLetters[sideLetterIdx].highWaterMarkUSD); FHE.allow(sideLetters[sideLetterIdx].highWaterMarkUSD, sideLetters[sideLetterIdx].investor);
    }

    function terminateSideLetter(uint256 sideLetterIdx) external onlyFundCompliance {
        sideLetters[sideLetterIdx].active = false;
        emit SideLetterTerminated(sideLetterIdx);
    }

    function allowCapitalStats(address viewer) external onlyOwner {
        FHE.allow(_totalCommittedCapitalUSD, viewer);
    }
}
