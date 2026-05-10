// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialReinsuranceTreaty - Encrypted cat XL reinsurance treaty with private loss reporting
contract ConfidentialReinsuranceTreaty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Treaty {
        address cedant;          // primary insurer
        address reinsurer;
        euint64 retentionLimit;  // cedant keeps losses below this
        euint64 coverLimit;      // reinsurer covers between retention and this
        euint64 premiumPaid;
        euint64 totalLossReported;
        euint64 totalRecovered;
        uint256 treatyStart;
        uint256 treatyEnd;
        bool    active;
    }

    struct LossEvent {
        string  eventId;
        euint64 grossLoss;
        euint64 cedantRetention;
        euint64 reinsurerLiability;
        euint64 recovered;
        bool    settled;
        uint256 reportedAt;
    }

    mapping(uint256 => Treaty)    public treaties;
    mapping(uint256 => LossEvent[]) private lossEvents;
    mapping(address => bool)      public approvedCedants;
    mapping(address => bool)      public approvedReinsurers;
    uint256 public treatyCount;

    event TreatyExecuted(uint256 indexed treatyId, address cedant, address reinsurer);
    event LossReported(uint256 indexed treatyId, uint256 eventIdx, string eventId);
    event LossSettled(uint256 indexed treatyId, uint256 eventIdx);

    constructor() Ownable(msg.sender) {}

    function approveCedant(address cedant)         external onlyOwner { approvedCedants[cedant] = true; }
    function approveReinsurer(address reinsurer)   external onlyOwner { approvedReinsurers[reinsurer] = true; }

    function executeTreaty(
        address reinsurer,
        uint256 durationDays,
        externalEuint64 encRetention, bytes calldata retentionProof,
        externalEuint64 encCover,     bytes calldata coverProof,
        externalEuint64 encPremium,   bytes calldata premiumProof
    ) external returns (uint256 treatyId) {
        require(approvedCedants[msg.sender],    "Not approved cedant");
        require(approvedReinsurers[reinsurer],  "Not approved reinsurer");
        treatyId = treatyCount++;
        Treaty storage t = treaties[treatyId];
        t.cedant           = msg.sender;
        t.reinsurer        = reinsurer;
        t.retentionLimit   = FHE.fromExternal(encRetention, retentionProof);
        t.coverLimit       = FHE.fromExternal(encCover,     coverProof);
        t.premiumPaid      = FHE.fromExternal(encPremium,   premiumProof);
        t.totalLossReported = FHE.asEuint64(0);
        t.totalRecovered    = FHE.asEuint64(0);
        t.treatyStart       = block.timestamp;
        t.treatyEnd         = block.timestamp + durationDays * 1 days;
        t.active            = true;
        FHE.allowThis(t.retentionLimit); FHE.allowThis(t.coverLimit); FHE.allowThis(t.premiumPaid);
        FHE.allowThis(t.totalLossReported); FHE.allowThis(t.totalRecovered);
        FHE.allow(t.retentionLimit, msg.sender); FHE.allow(t.coverLimit, msg.sender);
        FHE.allow(t.retentionLimit, reinsurer);  FHE.allow(t.coverLimit, reinsurer);
        FHE.allowTransient(t.premiumPaid, reinsurer);
        emit TreatyExecuted(treatyId, msg.sender, reinsurer);
    }

    function reportLoss(
        uint256 treatyId,
        string calldata eventId,
        externalEuint64 encGrossLoss, bytes calldata inputProof
    ) external returns (uint256 eventIdx) {
        Treaty storage t = treaties[treatyId];
        require(t.cedant == msg.sender, "Not cedant");
        require(t.active && block.timestamp <= t.treatyEnd, "Treaty inactive");
        euint64 gross = FHE.fromExternal(encGrossLoss, inputProof);
        // cedant retention = min(gross, retentionLimit)
        ebool grossBelowRetention = FHE.le(gross, t.retentionLimit);
        euint64 retention = FHE.select(grossBelowRetention, gross, t.retentionLimit);
        // reinsurer covers = min(gross - retention, coverLimit)
        ebool _safeSub63 = FHE.ge(gross, retention);
        euint64 excess    = FHE.select(_safeSub63, FHE.sub(gross, retention), FHE.asEuint64(0));
        ebool excessBelowCover = FHE.le(excess, t.coverLimit);
        euint64 reLiability = FHE.select(excessBelowCover, excess, t.coverLimit);

        lossEvents[treatyId].push(LossEvent({
            eventId: eventId, grossLoss: gross,
            cedantRetention: retention, reinsurerLiability: reLiability,
            recovered: FHE.asEuint64(0), settled: false, reportedAt: block.timestamp
        }));
        eventIdx = lossEvents[treatyId].length - 1;
        t.totalLossReported = FHE.add(t.totalLossReported, gross);
        FHE.allowThis(lossEvents[treatyId][eventIdx].grossLoss);
        FHE.allowThis(lossEvents[treatyId][eventIdx].reinsurerLiability);
        FHE.allowThis(lossEvents[treatyId][eventIdx].recovered);
        FHE.allowThis(t.totalLossReported);
        FHE.allow(lossEvents[treatyId][eventIdx].reinsurerLiability, t.reinsurer);
        emit LossReported(treatyId, eventIdx, eventId);
    }

    function settleLoss(uint256 treatyId, uint256 eventIdx) external onlyOwner nonReentrant {
        Treaty storage t = treaties[treatyId];
        LossEvent storage e = lossEvents[treatyId][eventIdx];
        require(!e.settled, "Settled");
        e.settled   = true;
        e.recovered = e.reinsurerLiability;
        t.totalRecovered = FHE.add(t.totalRecovered, e.recovered);
        FHE.allowThis(e.recovered); FHE.allowThis(t.totalRecovered);
        FHE.allow(e.recovered, t.cedant);
        FHE.allowTransient(e.recovered, t.cedant);
        emit LossSettled(treatyId, eventIdx);
    }
}
