// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateLaborUnionWageNegotiation
/// @notice Encrypted collective bargaining: hidden union wage demands, confidential employer
///         counteroffers, private arbitration scores, and encrypted economic data
///         (CPI, productivity) used in negotiation modeling.
contract PrivateLaborUnionWageNegotiation is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum NegotiationStage { Preparatory, Tabling, BargainingZone, Mediation, Arbitration, Agreement, Impasse }
    enum ContractType { MultiYear, Annual, SectorWide, Enterprise }

    struct CBANegotiation {
        address union;
        address employer;
        address mediator;
        ContractType contractType;
        string industryCode;
        euint64 unionWageDemandBps;    // encrypted union demand (wage increase bps)
        euint64 employerCounterBps;    // encrypted employer counter (bps)
        euint64 agreedWageIncreaseBps; // encrypted agreed increase
        euint64 workerCount;           // encrypted workers covered
        euint64 economicImpactUSD;     // encrypted annual payroll impact
        euint16 productivityIndexBps;  // encrypted productivity improvement bps
        euint16 cpiInflationBps;       // encrypted CPI reference bps
        NegotiationStage stage;
        uint256 startDate;
        uint256 expiryDate;
    }

    struct ArbitrationAward {
        uint256 negotiationId;
        address arbitrator;
        euint64 awardedWageIncreaseBps;// encrypted arbitration award
        euint8  confidenceScore;       // encrypted arbitrator confidence
        uint256 awardedAt;
    }

    mapping(uint256 => CBANegotiation) private negotiations;
    mapping(uint256 => ArbitrationAward) private awards;
    mapping(address => bool) public isCertifiedArbitrator;
    mapping(address => bool) public isLaborBoard;

    uint256 public negotiationCount;
    uint256 public awardCount;
    euint64 private _totalWorkersNegotiating;
    euint64 private _totalAgreedWageImpactUSD;

    event NegotiationStarted(uint256 indexed id, string industryCode, ContractType contractType);
    event StageAdvanced(uint256 indexed id, NegotiationStage newStage);
    event AgreementReached(uint256 indexed id);
    event ArbitrationAwarded(uint256 indexed awardId, uint256 negotiationId);

    modifier onlyArbitrator() {
        require(isCertifiedArbitrator[msg.sender] || msg.sender == owner(), "Not arbitrator");
        _;
    }

    modifier onlyLaborBoard() {
        require(isLaborBoard[msg.sender] || msg.sender == owner(), "Not labor board");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalWorkersNegotiating = FHE.asEuint64(0);
        _totalAgreedWageImpactUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalWorkersNegotiating);
        FHE.allowThis(_totalAgreedWageImpactUSD);
        isCertifiedArbitrator[msg.sender] = true;
        isLaborBoard[msg.sender] = true;
    }

    function addArbitrator(address a) external onlyOwner { isCertifiedArbitrator[a] = true; }
    function addLaborBoard(address lb) external onlyOwner { isLaborBoard[lb] = true; }

    function startNegotiation(
        address employer,
        address mediator,
        ContractType contractType,
        string calldata industryCode,
        externalEuint64 encUnionDemand, bytes calldata udProof,
        externalEuint64 encWorkerCount, bytes calldata wcProof,
        externalEuint16 encProductivity, bytes calldata prodProof,
        externalEuint16 encCPI, bytes calldata cpiProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        euint64 unionDemand = FHE.fromExternal(encUnionDemand, udProof);
        euint64 workerCount = FHE.fromExternal(encWorkerCount, wcProof);
        euint16 productivity = FHE.fromExternal(encProductivity, prodProof);
        euint16 cpi = FHE.fromExternal(encCPI, cpiProof);
        id = negotiationCount++;
        negotiations[id] = CBANegotiation({
            union: msg.sender, employer: employer, mediator: mediator,
            contractType: contractType, industryCode: industryCode,
            unionWageDemandBps: unionDemand, employerCounterBps: FHE.asEuint64(0),
            agreedWageIncreaseBps: FHE.asEuint64(0), workerCount: workerCount,
            economicImpactUSD: FHE.asEuint64(0), productivityIndexBps: productivity,
            cpiInflationBps: cpi, stage: NegotiationStage.Tabling,
            startDate: block.timestamp, expiryDate: block.timestamp + durationDays * 1 days
        });
        _totalWorkersNegotiating = FHE.add(_totalWorkersNegotiating, workerCount);
        FHE.allowThis(negotiations[id].unionWageDemandBps); FHE.allow(negotiations[id].unionWageDemandBps, msg.sender); FHE.allow(negotiations[id].unionWageDemandBps, mediator);
        FHE.allowThis(negotiations[id].employerCounterBps); FHE.allow(negotiations[id].employerCounterBps, employer);
        FHE.allowThis(negotiations[id].agreedWageIncreaseBps);
        FHE.allowThis(negotiations[id].workerCount); FHE.allow(negotiations[id].workerCount, msg.sender);
        FHE.allowThis(negotiations[id].productivityIndexBps);
        FHE.allowThis(negotiations[id].cpiInflationBps);
        FHE.allowThis(_totalWorkersNegotiating);
        emit NegotiationStarted(id, industryCode, contractType);
    }

    function submitEmployerCounter(
        uint256 negotiationId,
        externalEuint64 encCounterBps, bytes calldata proof
    ) external {
        CBANegotiation storage n = negotiations[negotiationId];
        require(msg.sender == n.employer, "Not employer");
        euint64 counter = FHE.fromExternal(encCounterBps, proof);
        n.employerCounterBps = counter;
        FHE.allowThis(n.employerCounterBps); FHE.allow(n.employerCounterBps, n.employer); FHE.allow(n.employerCounterBps, n.union); FHE.allow(n.employerCounterBps, n.mediator);
    }

    function advanceStage(uint256 negotiationId, NegotiationStage newStage) external {
        CBANegotiation storage n = negotiations[negotiationId];
        require(msg.sender == n.mediator || isLaborBoard[msg.sender], "Not authorized");
        n.stage = newStage;
        emit StageAdvanced(negotiationId, newStage);
    }

    function reachAgreement(
        uint256 negotiationId,
        externalEuint64 encAgreedBps, bytes calldata proof,
        externalEuint64 encEconomicImpact, bytes calldata eiProof
    ) external {
        CBANegotiation storage n = negotiations[negotiationId];
        require(msg.sender == n.mediator || msg.sender == n.union || msg.sender == n.employer, "Not party");
        euint64 agreed = FHE.fromExternal(encAgreedBps, proof);
        euint64 econImpact = FHE.fromExternal(encEconomicImpact, eiProof);
        n.agreedWageIncreaseBps = agreed;
        n.economicImpactUSD = econImpact;
        n.stage = NegotiationStage.Agreement;
        _totalAgreedWageImpactUSD = FHE.add(_totalAgreedWageImpactUSD, econImpact);
        FHE.allowThis(n.agreedWageIncreaseBps); FHE.allow(n.agreedWageIncreaseBps, n.union); FHE.allow(n.agreedWageIncreaseBps, n.employer);
        FHE.allowThis(n.economicImpactUSD); FHE.allow(n.economicImpactUSD, n.employer);
        FHE.allowThis(_totalAgreedWageImpactUSD);
        emit AgreementReached(negotiationId);
    }

    function issueArbitrationAward(
        uint256 negotiationId,
        externalEuint64 encAwardBps, bytes calldata aProof,
        externalEuint8 encConfidence, bytes calldata confProof
    ) external onlyArbitrator returns (uint256 awardId) {
        euint64 awardBps = FHE.fromExternal(encAwardBps, aProof);
        euint8 confidence = FHE.fromExternal(encConfidence, confProof);
        awardId = awardCount++;
        awards[awardId] = ArbitrationAward({
            negotiationId: negotiationId, arbitrator: msg.sender,
            awardedWageIncreaseBps: awardBps, confidenceScore: confidence,
            awardedAt: block.timestamp
        });
        CBANegotiation storage n = negotiations[negotiationId];
        FHE.allowThis(awards[awardId].awardedWageIncreaseBps); FHE.allow(awards[awardId].awardedWageIncreaseBps, n.union); FHE.allow(awards[awardId].awardedWageIncreaseBps, n.employer);
        FHE.allowThis(awards[awardId].confidenceScore);
        emit ArbitrationAwarded(awardId, negotiationId);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalWorkersNegotiating, viewer);
        FHE.allow(_totalAgreedWageImpactUSD, viewer);
    }
}
