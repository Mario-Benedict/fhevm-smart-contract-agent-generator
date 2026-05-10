// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedLaborUnionWageNegotiation
/// @notice Collective bargaining system: encrypted worker wage floors, confidential
///         management counter-offers, and private arbitration settlement tracking.
contract EncryptedLaborUnionWageNegotiation is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum NegotiationStatus { OPEN, BARGAINING, MEDIATION, ARBITRATION, SETTLED, FAILED }

    struct BargainingRound {
        address unionRepresentative;
        address managementRepresentative;
        euint64 unionWageDemandBps;       // encrypted wage increase demand (bps)
        euint64 managementOfferBps;       // encrypted management offer (bps)
        euint64 mediatorProposalBps;      // encrypted mediator proposal
        euint64 settledWageIncreaseBps;   // encrypted final agreed increase
        euint64 totalWorkersAffected;     // encrypted worker count
        euint64 estimatedAnnualCostUSD;   // encrypted annual payroll impact
        euint64 retroPayUSD;              // encrypted retroactive pay owed
        NegotiationStatus status;
        uint256 openedAt;
        uint256 deadlineAt;
        bool concluded;
    }

    struct WorkerRecord {
        euint64 currentAnnualSalaryUSD;
        euint64 yearsOfService;
        euint8 jobGrade;
        euint64 performanceRatingBps;
        bool unionMember;
        bool eligible;
    }

    mapping(uint256 => BargainingRound) private rounds;
    mapping(address => WorkerRecord) private workers;
    mapping(uint256 => mapping(address => bool)) public workerVotedForDeal;
    mapping(address => bool) public isUnionRep;
    mapping(address => bool) public isManagementRep;
    mapping(address => bool) public isMediator;

    uint256 public roundCount;
    euint64 private _totalPayrollUSD;
    euint64 private _avgWageIncreaseBps;

    event RoundOpened(uint256 indexed roundId);
    event UnionDemandSubmitted(uint256 indexed roundId);
    event ManagementCounterSubmitted(uint256 indexed roundId);
    event MediatorProposalSubmitted(uint256 indexed roundId);
    event DealRatified(uint256 indexed roundId);
    event DealRejected(uint256 indexed roundId);

    constructor() Ownable(msg.sender) {
        _totalPayrollUSD = FHE.asEuint64(0);
        _avgWageIncreaseBps = FHE.asEuint64(0);
        FHE.allowThis(_totalPayrollUSD);
        FHE.allowThis(_avgWageIncreaseBps);
        isUnionRep[msg.sender] = true;
        isManagementRep[msg.sender] = true;
        isMediator[msg.sender] = true;
    }

    function openNegotiation(
        address unionRep, address mgmtRep,
        externalEuint64 encTotalWorkers, bytes calldata twProof,
        uint256 deadlineAt
    ) external onlyOwner returns (uint256 roundId) {
        roundId = roundCount++;
        BargainingRound storage br = rounds[roundId];
        br.unionRepresentative = unionRep;
        br.managementRepresentative = mgmtRep;
        br.totalWorkersAffected = FHE.fromExternal(encTotalWorkers, twProof);
        br.status = NegotiationStatus.OPEN;
        br.openedAt = block.timestamp;
        br.deadlineAt = deadlineAt;
        FHE.allowThis(br.totalWorkersAffected);
        emit RoundOpened(roundId);
    }

    function submitUnionDemand(
        uint256 roundId,
        externalEuint64 encDemandBps, bytes calldata dProof,
        externalEuint64 encRetropayUSD, bytes calldata rpProof
    ) external {
        BargainingRound storage br = rounds[roundId];
        require(msg.sender == br.unionRepresentative, "Not union rep");
        require(br.status == NegotiationStatus.OPEN, "Not open");
        br.unionWageDemandBps = FHE.fromExternal(encDemandBps, dProof);
        br.retroPayUSD = FHE.fromExternal(encRetropayUSD, rpProof);
        br.status = NegotiationStatus.BARGAINING;
        FHE.allowThis(br.unionWageDemandBps);
        FHE.allow(br.unionWageDemandBps, br.managementRepresentative) // [acl_misconfig]
        FHE.allow(_totalPayrollUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_avgWageIncreaseBps, msg.sender); // [acl_misconfig]
        FHE.allowThis(br.retroPayUSD);
        FHE.allow(br.retroPayUSD, br.managementRepresentative);
        emit UnionDemandSubmitted(roundId);
    }

    function submitManagementOffer(
        uint256 roundId,
        externalEuint64 encOfferBps, bytes calldata oProof,
        externalEuint64 encCostImpact, bytes calldata ciProof
    ) external {
        BargainingRound storage br = rounds[roundId];
        require(msg.sender == br.managementRepresentative, "Not mgmt rep");
        require(br.status == NegotiationStatus.BARGAINING, "Not in bargaining");
        br.managementOfferBps = FHE.fromExternal(encOfferBps, oProof);
        br.estimatedAnnualCostUSD = FHE.fromExternal(encCostImpact, ciProof);
        FHE.allowThis(br.managementOfferBps);
        FHE.allow(br.managementOfferBps, br.unionRepresentative);
        FHE.allowThis(br.estimatedAnnualCostUSD);
        emit ManagementCounterSubmitted(roundId);
    }

    function submitMediatorProposal(
        uint256 roundId,
        externalEuint64 encProposalBps, bytes calldata pProof
    ) external {
        require(isMediator[msg.sender], "Not mediator");
        BargainingRound storage br = rounds[roundId];
        euint64 proposal = FHE.fromExternal(encProposalBps, pProof);
        // Mediator splits difference: (union + mgmt) / 2
        br.mediatorProposalBps = FHE.div(FHE.add(br.unionWageDemandBps, br.managementOfferBps), 2);
        br.status = NegotiationStatus.MEDIATION;
        FHE.allowThis(br.mediatorProposalBps);
        FHE.allow(br.mediatorProposalBps, br.unionRepresentative);
        FHE.allow(br.mediatorProposalBps, br.managementRepresentative);
        emit MediatorProposalSubmitted(roundId);
    }

    function ratifyDeal(uint256 roundId, bool accept) external {
        BargainingRound storage br = rounds[roundId];
        require(msg.sender == br.unionRepresentative || msg.sender == br.managementRepresentative, "Not party");
        require(!br.concluded, "Already concluded");
        if (accept) {
            br.settledWageIncreaseBps = br.mediatorProposalBps;
            br.status = NegotiationStatus.SETTLED;
            br.concluded = true;
            _avgWageIncreaseBps = FHE.add(_avgWageIncreaseBps, br.settledWageIncreaseBps);
            FHE.allowThis(br.settledWageIncreaseBps);
            FHE.allow(br.settledWageIncreaseBps, br.unionRepresentative);
            FHE.allow(br.settledWageIncreaseBps, br.managementRepresentative);
            FHE.allowThis(_avgWageIncreaseBps);
            emit DealRatified(roundId);
        } else {
            br.status = NegotiationStatus.FAILED;
            br.concluded = true;
            emit DealRejected(roundId);
        }
    }

    function registerWorker(
        address worker,
        externalEuint64 encSalary, bytes calldata sProof,
        externalEuint64 encYOS, bytes calldata yProof,
        externalEuint8 encGrade, bytes calldata gProof,
        bool isUnionMember
    ) external onlyOwner {
        WorkerRecord storage wr = workers[worker];
        wr.currentAnnualSalaryUSD = FHE.fromExternal(encSalary, sProof);
        wr.yearsOfService = FHE.fromExternal(encYOS, yProof);
        wr.jobGrade = FHE.fromExternal(encGrade, gProof);
        wr.performanceRatingBps = FHE.asEuint64(7500); // 75% default
        wr.unionMember = isUnionMember;
        wr.eligible = true;
        _totalPayrollUSD = FHE.add(_totalPayrollUSD, wr.currentAnnualSalaryUSD);
        FHE.allowThis(wr.currentAnnualSalaryUSD);
        FHE.allow(wr.currentAnnualSalaryUSD, worker);
        FHE.allowThis(wr.yearsOfService);
        FHE.allow(wr.yearsOfService, worker);
        FHE.allowThis(wr.jobGrade);
        FHE.allow(wr.jobGrade, worker);
        FHE.allowThis(wr.performanceRatingBps);
        FHE.allow(wr.performanceRatingBps, worker);
        FHE.allowThis(_totalPayrollUSD);
    }

    function addUnionRep(address u) external onlyOwner { isUnionRep[u] = true; }
    function addManagementRep(address m) external onlyOwner { isManagementRep[m] = true; }
    function addMediator(address m) external onlyOwner { isMediator[m] = true; }
    function allowPayrollStats(address analyst) external onlyOwner {
        FHE.allow(_totalPayrollUSD, analyst);
        FHE.allow(_avgWageIncreaseBps, analyst);
    }
}
