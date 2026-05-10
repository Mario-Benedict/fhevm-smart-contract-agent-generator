// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCarbonCreditRegistryAndTrading
/// @notice Encrypted carbon credit registry: hidden project baselines, private
///         credit issuance volumes, confidential offset buyer identities,
///         and encrypted vintage retirement accounting.
contract PrivateCarbonCreditRegistryAndTrading is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ProjectType { REDD_Plus, SoilCarbon, BlueCarbonMangrove, DirectAirCapture, MethaneCombustion, IndustrialEfficiency }
    enum CreditStandard { VCS, GoldStandard, ACR, CAR, CDM }

    struct CarbonProject {
        address projectDeveloper;
        ProjectType projectType;
        CreditStandard standard;
        string projectRef;
        string country;
        euint64 baselineTonsCO2;       // encrypted baseline emissions
        euint64 creditsIssued;         // encrypted credits issued (tCO2)
        euint64 creditsRetired;        // encrypted credits retired
        euint64 pricePerCreditUSD;     // encrypted spot price
        euint16 additionalityScore;   // encrypted additionality rating
        bool verified;
        uint256 vintageYear;
    }

    struct CreditLedger {
        address holder;
        uint256 projectId;
        euint64 creditsHeld;           // encrypted holding
        euint64 totalPurchasedUSD;     // encrypted amount paid
    }

    mapping(uint256 => CarbonProject) private projects;
    mapping(uint256 => CreditLedger)  private ledgers;
    mapping(address => uint256[]) private holderLedgerIds;
    mapping(address => bool) public isCarbonVerifier;

    uint256 public projectCount;
    uint256 public ledgerCount;
    euint64 private _totalCreditsIssuedGlobal;
    euint64 private _totalCreditsRetiredGlobal;
    euint64 private _totalMarketValueUSD;

    event ProjectRegistered(uint256 indexed id, ProjectType projectType, CreditStandard standard);
    event CreditsIssued(uint256 indexed projectId, uint256 issuedAt);
    event CreditsTraded(uint256 indexed ledgerId, address buyer);
    event CreditsRetired(uint256 indexed ledgerId, uint256 retiredAt);

    modifier onlyCarbonVerifier() {
        require(isCarbonVerifier[msg.sender] || msg.sender == owner(), "Not carbon verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCreditsIssuedGlobal = FHE.asEuint64(0);
        _totalCreditsRetiredGlobal = FHE.asEuint64(0);
        _totalMarketValueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCreditsIssuedGlobal);
        FHE.allowThis(_totalCreditsRetiredGlobal);
        FHE.allowThis(_totalMarketValueUSD);
        isCarbonVerifier[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addVerifier(address v) external onlyOwner { isCarbonVerifier[v] = true; }

    function registerProject(
        ProjectType projectType, CreditStandard standard,
        string calldata projectRef, string calldata country,
        externalEuint64 encBaseline, bytes calldata blProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 vintageYear
    ) external returns (uint256 id) {
        euint64 baseline = FHE.fromExternal(encBaseline, blProof);
        euint64 price    = FHE.fromExternal(encPrice, pProof);
        id = projectCount++;
        CarbonProject storage _s0 = projects[id];
        _s0.projectDeveloper = msg.sender;
        _s0.projectType = projectType;
        _s0.standard = standard;
        _s0.projectRef = projectRef;
        _s0.country = country;
        _s0.baselineTonsCO2 = baseline;
        _s0.creditsIssued = FHE.asEuint64(0);
        _s0.creditsRetired = FHE.asEuint64(0);
        _s0.pricePerCreditUSD = price;
        _s0.additionalityScore = FHE.asEuint16(0);
        _s0.verified = false;
        _s0.vintageYear = vintageYear;
        FHE.allowThis(projects[id].baselineTonsCO2); FHE.allow(projects[id].baselineTonsCO2, msg.sender);
        FHE.allowThis(projects[id].creditsIssued); FHE.allow(projects[id].creditsIssued, msg.sender);
        FHE.allowThis(projects[id].creditsRetired);
        FHE.allowThis(projects[id].pricePerCreditUSD); FHE.allow(projects[id].pricePerCreditUSD, msg.sender);
        FHE.allowThis(projects[id].additionalityScore);
        emit ProjectRegistered(id, projectType, standard);
    }

    function verifyAndIssueCredits(
        uint256 projectId,
        externalEuint64 encCredits, bytes calldata proof,
        externalEuint16 encAdditionality, bytes calldata addProof
    ) external onlyCarbonVerifier {
        CarbonProject storage p = projects[projectId];
        euint64 credits = FHE.fromExternal(encCredits, proof);
        euint16 additionality = FHE.fromExternal(encAdditionality, addProof);
        p.creditsIssued = FHE.add(p.creditsIssued, credits);
        p.additionalityScore = additionality;
        p.verified = true;
        _totalCreditsIssuedGlobal = FHE.add(_totalCreditsIssuedGlobal, credits);
        FHE.allowThis(p.creditsIssued); FHE.allow(p.creditsIssued, p.projectDeveloper);
        FHE.allowThis(p.additionalityScore); FHE.allow(p.additionalityScore, p.projectDeveloper);
        FHE.allowThis(_totalCreditsIssuedGlobal);
        emit CreditsIssued(projectId, block.timestamp);
    }

    function buyCredits(uint256 projectId, externalEuint64 encAmt, bytes calldata proof) external whenNotPaused nonReentrant returns (uint256 ledgerId) {
        CarbonProject storage p = projects[projectId];
        require(p.verified, "Project not verified");
        euint64 amt = FHE.fromExternal(encAmt, proof);
        euint64 cost = FHE.mul(amt, p.pricePerCreditUSD);
        ledgerId = ledgerCount++;
        ledgers[ledgerId] = CreditLedger({
            holder: msg.sender, projectId: projectId, creditsHeld: amt, totalPurchasedUSD: cost
        });
        holderLedgerIds[msg.sender].push(ledgerId);
        _totalMarketValueUSD = FHE.add(_totalMarketValueUSD, cost);
        FHE.allowThis(ledgers[ledgerId].creditsHeld); FHE.allow(ledgers[ledgerId].creditsHeld, msg.sender);
        FHE.allowThis(ledgers[ledgerId].totalPurchasedUSD); FHE.allow(ledgers[ledgerId].totalPurchasedUSD, msg.sender);
        FHE.allowThis(_totalMarketValueUSD);
        emit CreditsTraded(ledgerId, msg.sender);
    }

    function retireCredits(uint256 ledgerId, externalEuint64 encAmt, bytes calldata proof) external nonReentrant {
        CreditLedger storage l = ledgers[ledgerId];
        require(l.holder == msg.sender, "Not holder");
        euint64 amt = FHE.fromExternal(encAmt, proof);
        ebool sufficient = FHE.ge(l.creditsHeld, amt);
        euint64 effAmt = FHE.select(sufficient, amt, l.creditsHeld);
        l.creditsHeld = FHE.sub(l.creditsHeld, effAmt);
        projects[l.projectId].creditsRetired = FHE.add(projects[l.projectId].creditsRetired, effAmt);
        _totalCreditsRetiredGlobal = FHE.add(_totalCreditsRetiredGlobal, effAmt);
        FHE.allowThis(l.creditsHeld); FHE.allow(l.creditsHeld, msg.sender);
        FHE.allowThis(projects[l.projectId].creditsRetired);
        FHE.allowThis(_totalCreditsRetiredGlobal);
        emit CreditsRetired(ledgerId, block.timestamp);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalCreditsIssuedGlobal, viewer);
        FHE.allow(_totalCreditsRetiredGlobal, viewer);
        FHE.allow(_totalMarketValueUSD, viewer);
    }

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