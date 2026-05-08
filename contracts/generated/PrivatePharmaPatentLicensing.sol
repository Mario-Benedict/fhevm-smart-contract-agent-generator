// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivatePharmaPatentLicensing
/// @notice Pharmaceutical patent licensing platform: encrypted royalty stacks,
///         encrypted milestone payments, and confidential sublicense terms.
contract PrivatePharmaPatentLicensing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum PatentStage { Preclinical, PhaseI, PhaseII, PhaseIII, Approved, PostMarket }
    enum LicenseScope { Exclusive, NonExclusive, Sublicensable, Territorial }

    struct PharmaceuticalPatent {
        address originator;
        string patentNumber;
        string drugName;
        string indication;
        PatentStage stage;
        euint64 upfrontPaymentUSD;     // encrypted upfront fee
        euint32 royaltyRateBps;        // encrypted royalty rate
        euint64 maxRoyaltyCap;         // encrypted royalty cap per year
        euint64 totalRoyaltiesEarned;  // encrypted cumulative royalties
        uint256 expiryDate;
        bool granted;
    }

    struct MilestonePayment {
        uint256 patentId;
        PatentStage triggerStage;
        euint64 milestoneAmountUSD;    // encrypted payment amount
        bool triggered;
        uint256 triggeredAt;
    }

    mapping(uint256 => PharmaceuticalPatent) private patents;
    mapping(uint256 => MilestonePayment[]) private milestones;
    mapping(address => bool) public isPharmaCo;
    mapping(address => bool) public isPatentOffice;

    uint256 public patentCount;
    euint64 private _totalLicenseRevenue;

    event PatentLicensed(uint256 indexed id, string patentNo, LicenseScope scope);
    event MilestoneTriggered(uint256 indexed patentId, uint256 milestoneIndex, PatentStage stage);
    event RoyaltyPaid(uint256 indexed patentId);

    modifier onlyPatentOffice() {
        require(isPatentOffice[msg.sender] || msg.sender == owner(), "Not patent office");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLicenseRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalLicenseRevenue);
        isPatentOffice[msg.sender] = true;
    }

    function addPharmaCo(address p) external onlyOwner { isPharmaCo[p] = true; }
    function addPatentOffice(address o) external onlyOwner { isPatentOffice[o] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function licensePatent(
        string calldata patentNo, string calldata drugName, string calldata indication,
        PatentStage stage, LicenseScope scope,
        externalEuint64 encUpfront, bytes calldata uProof,
        externalEuint32 encRoyalty, bytes calldata rProof,
        externalEuint64 encRoyaltyCap, bytes calldata capProof,
        uint256 licenseYears
    ) external whenNotPaused returns (uint256 id) {
        require(isPharmaCo[msg.sender], "Not pharma company");
        euint64 upfront = FHE.fromExternal(encUpfront, uProof);
        euint32 royalty = FHE.fromExternal(encRoyalty, rProof);
        euint64 cap = FHE.fromExternal(encRoyaltyCap, capProof);
        id = patentCount++;
        patents[id] = PharmaceuticalPatent({
            originator: msg.sender, patentNumber: patentNo, drugName: drugName,
            indication: indication, stage: stage,
            upfrontPaymentUSD: upfront, royaltyRateBps: royalty, maxRoyaltyCap: cap,
            totalRoyaltiesEarned: FHE.asEuint64(0),
            expiryDate: block.timestamp + licenseYears * 365 days, granted: true
        });
        _totalLicenseRevenue = FHE.add(_totalLicenseRevenue, upfront);
        FHE.allowThis(patents[id].upfrontPaymentUSD); FHE.allow(patents[id].upfrontPaymentUSD, msg.sender);
        FHE.allowThis(patents[id].royaltyRateBps); FHE.allow(patents[id].royaltyRateBps, msg.sender);
        FHE.allowThis(patents[id].maxRoyaltyCap); FHE.allow(patents[id].maxRoyaltyCap, msg.sender);
        FHE.allowThis(patents[id].totalRoyaltiesEarned); FHE.allow(patents[id].totalRoyaltiesEarned, msg.sender);
        FHE.allowThis(_totalLicenseRevenue);
        emit PatentLicensed(id, patentNo, scope);
    }

    function addMilestone(
        uint256 patentId, PatentStage triggerStage,
        externalEuint64 encAmount, bytes calldata proof
    ) external {
        require(patents[patentId].originator == msg.sender, "Not originator");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        milestones[patentId].push(MilestonePayment({
            patentId: patentId, triggerStage: triggerStage,
            milestoneAmountUSD: amount, triggered: false, triggeredAt: 0
        }));
        FHE.allowThis(amount); FHE.allow(amount, msg.sender);
    }

    function advanceStage(uint256 patentId, PatentStage newStage) external onlyPatentOffice {
        patents[patentId].stage = newStage;
        // Trigger any matching milestones
        MilestonePayment[] storage ms = milestones[patentId];
        for (uint256 i = 0; i < ms.length; i++) {
            if (ms[i].triggerStage == newStage && !ms[i].triggered) {
                ms[i].triggered = true;
                ms[i].triggeredAt = block.timestamp;
                _totalLicenseRevenue = FHE.add(_totalLicenseRevenue, ms[i].milestoneAmountUSD);
                FHE.allowThis(_totalLicenseRevenue);
                emit MilestoneTriggered(patentId, i, newStage);
            }
        }
    }

    function payRoyalty(uint256 patentId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        PharmaceuticalPatent storage p = patents[patentId];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinCap = FHE.le(FHE.add(p.totalRoyaltiesEarned, amount), p.maxRoyaltyCap);
        euint64 actual = FHE.select(withinCap, amount, FHE.sub(p.maxRoyaltyCap, p.totalRoyaltiesEarned));
        p.totalRoyaltiesEarned = FHE.add(p.totalRoyaltiesEarned, actual);
        _totalLicenseRevenue = FHE.add(_totalLicenseRevenue, actual);
        FHE.allowThis(p.totalRoyaltiesEarned); FHE.allow(p.totalRoyaltiesEarned, p.originator);
        FHE.allowThis(_totalLicenseRevenue);
        emit RoyaltyPaid(patentId);
    }

    function allowIPStats(address viewer) external onlyOwner {
        FHE.allow(_totalLicenseRevenue, viewer);
    }
}
