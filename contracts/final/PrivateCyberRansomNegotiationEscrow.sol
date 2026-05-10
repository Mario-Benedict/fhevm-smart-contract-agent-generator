// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCyberRansomNegotiationEscrow
/// @notice Confidential ransomware incident response escrow: encrypted ransom demand amounts,
///         hidden negotiation positions, private law enforcement coordination flags, and
///         encrypted cyber insurance claim integration for incident costs.
contract PrivateCyberRansomNegotiationEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum IncidentSeverity { Low, Medium, High, Critical, Catastrophic }
    enum NegotiationStatus { OpenDemand, Negotiating, PaymentHeld, Released, LawEnforcement, Resolved }

    struct RansomIncident {
        address victimOrganization;
        address negotiator;
        IncidentSeverity severity;
        string incidentRef;
        euint64 initialDemandUSD;      // encrypted initial demand
        euint64 negotiatedAmountUSD;   // encrypted negotiated settlement
        euint64 insuranceCoverageUSD;  // encrypted insurance coverage
        euint64 cyberCostsTotalUSD;    // encrypted total incident costs
        euint8  lawEnforcementFlag;    // encrypted LEA involvement flag
        NegotiationStatus status;
        uint256 detectedAt;
        uint256 deadlineAt;
    }

    struct InsuranceClaim {
        uint256 incidentId;
        address insurer;
        euint64 claimAmountUSD;        // encrypted claimed amount
        euint64 approvedAmountUSD;     // encrypted approved payout
        euint8  subrogationFlag;       // encrypted subrogation flag
        bool settled;
        uint256 claimedAt;
    }

    mapping(uint256 => RansomIncident) private incidents;
    mapping(uint256 => InsuranceClaim) private claims;
    mapping(address => bool) public isNegotiator;
    mapping(address => bool) public isInsuranceAdjuster;

    uint256 public incidentCount;
    uint256 public claimCount;
    euint64 private _totalRansomPaidUSD;
    euint64 private _totalInsurancePayoutsUSD;

    event IncidentReported(uint256 indexed id, string incidentRef, IncidentSeverity severity);
    event NegotiationUpdated(uint256 indexed id, NegotiationStatus status);
    event InsuranceClaimFiled(uint256 indexed claimId, uint256 incidentId);

    modifier onlyNegotiator() {
        require(isNegotiator[msg.sender] || msg.sender == owner(), "Not negotiator");
        _;
    }

    modifier onlyAdjuster() {
        require(isInsuranceAdjuster[msg.sender] || msg.sender == owner(), "Not adjuster");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRansomPaidUSD = FHE.asEuint64(0);
        _totalInsurancePayoutsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalRansomPaidUSD);
        FHE.allowThis(_totalInsurancePayoutsUSD);
        isNegotiator[msg.sender] = true;
        isInsuranceAdjuster[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addNegotiator(address n) external onlyOwner { isNegotiator[n] = true; }
    function addAdjuster(address a) external onlyOwner { isInsuranceAdjuster[a] = true; }

    function reportIncident(
        string calldata incidentRef,
        IncidentSeverity severity,
        address negotiator,
        externalEuint64 encInitialDemand, bytes calldata idProof,
        externalEuint64 encInsuranceCoverage, bytes calldata icProof,
        uint256 deadlineDays
    ) external whenNotPaused returns (uint256 id) {
        euint64 demand = FHE.fromExternal(encInitialDemand, idProof);
        euint64 coverage = FHE.fromExternal(encInsuranceCoverage, icProof);
        id = incidentCount++;
        RansomIncident storage _s0 = incidents[id];
        _s0.victimOrganization = msg.sender;
        _s0.negotiator = negotiator;
        _s0.severity = severity;
        _s0.incidentRef = incidentRef;
        _s0.initialDemandUSD = demand;
        _s0.negotiatedAmountUSD = FHE.asEuint64(0);
        _s0.insuranceCoverageUSD = coverage;
        _s0.cyberCostsTotalUSD = FHE.asEuint64(0);
        _s0.lawEnforcementFlag = FHE.asEuint8(0);
        _s0.status = NegotiationStatus.OpenDemand;
        _s0.detectedAt = block.timestamp;
        _s0.deadlineAt = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(incidents[id].initialDemandUSD); FHE.allow(incidents[id].initialDemandUSD, msg.sender); FHE.allow(incidents[id].initialDemandUSD, negotiator);
        FHE.allowThis(incidents[id].negotiatedAmountUSD);
        FHE.allowThis(incidents[id].insuranceCoverageUSD); FHE.allow(incidents[id].insuranceCoverageUSD, msg.sender);
        FHE.allowThis(incidents[id].cyberCostsTotalUSD); FHE.allow(incidents[id].cyberCostsTotalUSD, msg.sender);
        FHE.allowThis(incidents[id].lawEnforcementFlag);
        emit IncidentReported(id, incidentRef, severity);
    }

    function updateNegotiation(
        uint256 incidentId,
        externalEuint64 encNegotiatedAmt, bytes calldata naProof,
        externalEuint8 encLEAFlag, bytes calldata leaProof,
        NegotiationStatus newStatus
    ) external onlyNegotiator {
        RansomIncident storage inc = incidents[incidentId];
        euint64 negotiated = FHE.fromExternal(encNegotiatedAmt, naProof);
        euint8 leaFlag = FHE.fromExternal(encLEAFlag, leaProof);
        inc.negotiatedAmountUSD = negotiated;
        inc.lawEnforcementFlag = leaFlag;
        inc.status = newStatus;
        FHE.allowThis(inc.negotiatedAmountUSD); FHE.allow(inc.negotiatedAmountUSD, inc.victimOrganization); FHE.allow(inc.negotiatedAmountUSD, inc.negotiator);
        FHE.allowThis(inc.lawEnforcementFlag);
        emit NegotiationUpdated(incidentId, newStatus);
    }

    function releasePayment(uint256 incidentId) external onlyNegotiator nonReentrant {
        RansomIncident storage inc = incidents[incidentId];
        require(inc.status == NegotiationStatus.PaymentHeld, "Not in payment held");
        inc.status = NegotiationStatus.Released;
        _totalRansomPaidUSD = FHE.add(_totalRansomPaidUSD, inc.negotiatedAmountUSD);
        FHE.allowThis(_totalRansomPaidUSD);
    }

    function fileInsuranceClaim(
        uint256 incidentId,
        address insurer,
        externalEuint64 encClaimAmt, bytes calldata caProof
    ) external returns (uint256 claimId) {
        RansomIncident storage inc = incidents[incidentId];
        require(msg.sender == inc.victimOrganization, "Not victim organization");
        euint64 claimAmt = FHE.fromExternal(encClaimAmt, caProof);
        claimId = claimCount++;
        claims[claimId] = InsuranceClaim({
            incidentId: incidentId, insurer: insurer, claimAmountUSD: claimAmt,
            approvedAmountUSD: FHE.asEuint64(0), subrogationFlag: FHE.asEuint8(0),
            settled: false, claimedAt: block.timestamp
        });
        FHE.allowThis(claims[claimId].claimAmountUSD); FHE.allow(claims[claimId].claimAmountUSD, msg.sender); FHE.allow(claims[claimId].claimAmountUSD, insurer);
        FHE.allowThis(claims[claimId].approvedAmountUSD);
        FHE.allowThis(claims[claimId].subrogationFlag);
        emit InsuranceClaimFiled(claimId, incidentId);
    }

    function approveInsuranceClaim(
        uint256 claimId,
        externalEuint64 encApprovedAmt, bytes calldata proof
    ) external onlyAdjuster nonReentrant {
        InsuranceClaim storage c = claims[claimId];
        require(!c.settled, "Already settled");
        euint64 approved = FHE.fromExternal(encApprovedAmt, proof);
        c.approvedAmountUSD = approved;
        c.settled = true;
        _totalInsurancePayoutsUSD = FHE.add(_totalInsurancePayoutsUSD, approved);
        FHE.allowThis(c.approvedAmountUSD);
        FHE.allow(c.approvedAmountUSD, incidents[c.incidentId].victimOrganization);
        FHE.allowThis(_totalInsurancePayoutsUSD);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRansomPaidUSD, viewer);
        FHE.allow(_totalInsurancePayoutsUSD, viewer);
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