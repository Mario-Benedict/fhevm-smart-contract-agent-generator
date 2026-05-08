// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDeepSeaMiningRoyalty
/// @notice Seabed mining concession royalties: encrypted polymetallic nodule quantities,
///         encrypted royalty rates paid to the International Seabed Authority (ISA).
contract PrivateDeepSeaMiningRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum MineralNodeule { Polymetallic, CobaltCrust, MassiveSulfide }
    enum ConcessionStatus { Active, Suspended, Revoked, Expired }

    struct Concession {
        address operator;
        string blockId;
        string oceanRegion;             // e.g. "CCZ", "IndianOcean"
        MineralNodeule primaryMineral;
        euint64 licenseDepthMeters;     // encrypted water depth
        euint64 annualProductionTonnes; // encrypted production quota
        euint32 royaltyRateBps;        // encrypted royalty rate
        euint64 totalRoyaltiesPaidUSD; // encrypted cumulative royalties
        uint256 licenseExpiry;
        ConcessionStatus status;
    }

    struct ProductionReport {
        uint256 concessionId;
        euint64 extractedTonnes;        // encrypted extraction
        euint64 royaltyDueUSD;         // encrypted royalty payable
        uint256 reportingPeriod;
        bool paid;
    }

    mapping(uint256 => Concession) private concessions;
    mapping(uint256 => ProductionReport[]) private reports;
    mapping(address => bool) public isISAAuthority;

    uint256 public concessionCount;
    euint64 private _totalRoyaltiesUSD;
    euint64 private _totalExtractionTonnes;

    event ConcessionGranted(uint256 indexed id, address operator, string blockId);
    event ProductionReported(uint256 indexed id, uint256 period);
    event RoyaltySettled(uint256 indexed id, uint256 reportIndex);

    modifier onlyISA() {
        require(isISAAuthority[msg.sender] || msg.sender == owner(), "Not ISA");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRoyaltiesUSD = FHE.asEuint64(0);
        _totalExtractionTonnes = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltiesUSD);
        FHE.allowThis(_totalExtractionTonnes);
        isISAAuthority[msg.sender] = true;
    }

    function addISA(address a) external onlyOwner { isISAAuthority[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function grantConcession(
        address operator,
        string calldata blockId,
        string calldata oceanRegion,
        MineralNodeule mineral,
        externalEuint64 encDepth, bytes calldata dProof,
        externalEuint64 encProductionQuota, bytes calldata pProof,
        externalEuint32 encRoyaltyRate, bytes calldata rProof,
        uint256 licenseYears
    ) external onlyISA whenNotPaused returns (uint256 id) {
        euint64 depth = FHE.fromExternal(encDepth, dProof);
        euint64 quota = FHE.fromExternal(encProductionQuota, pProof);
        euint32 royaltyRate = FHE.fromExternal(encRoyaltyRate, rProof);
        id = concessionCount++;
        concessions[id] = Concession({
            operator: operator, blockId: blockId, oceanRegion: oceanRegion,
            primaryMineral: mineral, licenseDepthMeters: depth,
            annualProductionTonnes: quota, royaltyRateBps: royaltyRate,
            totalRoyaltiesPaidUSD: FHE.asEuint64(0),
            licenseExpiry: block.timestamp + licenseYears * 365 days,
            status: ConcessionStatus.Active
        });
        FHE.allowThis(concessions[id].licenseDepthMeters);
        FHE.allow(concessions[id].licenseDepthMeters, operator);
        FHE.allowThis(concessions[id].annualProductionTonnes);
        FHE.allow(concessions[id].annualProductionTonnes, operator);
        FHE.allowThis(concessions[id].royaltyRateBps);
        FHE.allow(concessions[id].royaltyRateBps, operator);
        FHE.allowThis(concessions[id].totalRoyaltiesPaidUSD);
        emit ConcessionGranted(id, operator, blockId);
    }

    function submitProductionReport(
        uint256 concessionId,
        externalEuint64 encExtracted, bytes calldata eProof,
        uint256 period
    ) external nonReentrant {
        Concession storage c = concessions[concessionId];
        require(c.operator == msg.sender && c.status == ConcessionStatus.Active, "Not operator or inactive");
        euint64 extracted = FHE.fromExternal(encExtracted, eProof);
        // Clamp to quota
        ebool withinQuota = FHE.le(extracted, c.annualProductionTonnes);
        euint64 actual = FHE.select(withinQuota, extracted, c.annualProductionTonnes);
        euint64 royalty = FHE.mul(actual, FHE.asEuint64(0)); // royalty placeholder
        ProductionReport memory rep = ProductionReport({
            concessionId: concessionId, extractedTonnes: actual,
            royaltyDueUSD: royalty, reportingPeriod: period, paid: false
        });
        reports[concessionId].push(rep);
        _totalExtractionTonnes = FHE.add(_totalExtractionTonnes, actual);
        FHE.allowThis(rep.extractedTonnes);
        FHE.allow(rep.extractedTonnes, owner());
        FHE.allowThis(rep.royaltyDueUSD);
        FHE.allow(rep.royaltyDueUSD, owner());
        FHE.allowThis(_totalExtractionTonnes);
        emit ProductionReported(concessionId, period);
    }

    function settleRoyalty(uint256 concessionId, uint256 reportIndex) external onlyISA nonReentrant {
        Concession storage c = concessions[concessionId];
        ProductionReport storage rep = reports[concessionId][reportIndex];
        require(!rep.paid, "Already paid");
        rep.paid = true;
        c.totalRoyaltiesPaidUSD = FHE.add(c.totalRoyaltiesPaidUSD, rep.royaltyDueUSD);
        _totalRoyaltiesUSD = FHE.add(_totalRoyaltiesUSD, rep.royaltyDueUSD);
        FHE.allowThis(c.totalRoyaltiesPaidUSD);
        FHE.allow(c.totalRoyaltiesPaidUSD, c.operator);
        FHE.allowThis(_totalRoyaltiesUSD);
        emit RoyaltySettled(concessionId, reportIndex);
    }

    function suspendConcession(uint256 id) external onlyISA { concessions[id].status = ConcessionStatus.Suspended; }
    function revokeConcession(uint256 id) external onlyISA { concessions[id].status = ConcessionStatus.Revoked; }

    function allowSeabedStats(address viewer) external onlyOwner {
        FHE.allow(_totalRoyaltiesUSD, viewer);
        FHE.allow(_totalExtractionTonnes, viewer);
    }
}
