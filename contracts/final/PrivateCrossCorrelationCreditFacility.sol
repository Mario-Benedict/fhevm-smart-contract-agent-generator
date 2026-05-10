// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCrossCorrelationCreditFacility
/// @notice Multi-bank syndicated credit facility: encrypted credit limits per borrower,
///         hidden utilization rates, private fee schedules, and confidential covenant
///         compliance scores shared only with the agent bank.
contract PrivateCrossCorrelationCreditFacility is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FacilityType { Revolving, TermLoan, BridgeLoan, MezzanineDebt }
    enum CovenantStatus { Compliant, Waiver, Breached }

    struct CreditFacility {
        address borrower;
        address agentBank;
        FacilityType facilityType;
        euint64 totalCommitmentUSD;   // encrypted total credit limit
        euint64 outstandingDrawUSD;   // encrypted drawn amount
        euint64 availableUSD;         // encrypted remaining availability
        euint16 spreadBps;            // encrypted margin over benchmark
        euint16 commitmentFeeBps;     // encrypted undrawn commitment fee
        euint8  covenantScore;        // encrypted compliance score 0-100
        CovenantStatus covenantStatus;
        uint256 maturityDate;
    }

    struct Drawdown {
        uint256 facilityId;
        address borrower;
        euint64 amountUSD;            // encrypted drawdown amount
        euint64 interestAccruedUSD;   // encrypted interest accrued
        uint256 drawnAt;
        bool repaid;
    }

    mapping(uint256 => CreditFacility) private facilities;
    mapping(uint256 => Drawdown) private drawdowns;
    mapping(address => bool) public isAgentBank;
    mapping(address => uint256[]) private borrowerFacilities;

    uint256 public facilityCount;
    uint256 public drawdownCount;
    euint64 private _totalCommitmentsUSD;
    euint64 private _totalOutstandingUSD;

    event FacilityCreated(uint256 indexed id, address borrower, FacilityType facilityType);
    event DrawdownMade(uint256 indexed drawId, uint256 facilityId);
    event DrawdownRepaid(uint256 indexed drawId);
    event CovenantUpdated(uint256 indexed facilityId, CovenantStatus status);

    modifier onlyAgentBank() {
        require(isAgentBank[msg.sender] || msg.sender == owner(), "Not agent bank");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalCommitmentsUSD = FHE.asEuint64(0);
        _totalOutstandingUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalCommitmentsUSD);
        FHE.allowThis(_totalOutstandingUSD);
        isAgentBank[msg.sender] = true;
    }

    function addAgentBank(address a) external onlyOwner { isAgentBank[a] = true; }

    function createFacility(
        address borrower,
        FacilityType facilityType,
        externalEuint64 encCommitment, bytes calldata cProof,
        externalEuint16 encSpread, bytes calldata sProof,
        externalEuint16 encCommitFee, bytes calldata cfProof,
        uint256 maturityDays
    ) external onlyAgentBank returns (uint256 id) {
        euint64 commitment = FHE.fromExternal(encCommitment, cProof);
        euint16 spread = FHE.fromExternal(encSpread, sProof);
        euint16 commitFee = FHE.fromExternal(encCommitFee, cfProof);
        id = facilityCount++;
        facilities[id].borrower = borrower;
        facilities[id].agentBank = msg.sender;
        facilities[id].facilityType = facilityType;
        facilities[id].totalCommitmentUSD = commitment;
        facilities[id].outstandingDrawUSD = FHE.asEuint64(0);
        facilities[id].availableUSD = commitment;
        facilities[id].spreadBps = spread;
        facilities[id].commitmentFeeBps = commitFee;
        facilities[id].covenantScore = FHE.asEuint8(100);
        facilities[id].covenantStatus = CovenantStatus.Compliant;
        facilities[id].maturityDate = block.timestamp + maturityDays * 1 days;
        _totalCommitmentsUSD = FHE.add(_totalCommitmentsUSD, commitment);
        borrowerFacilities[borrower].push(id);
        FHE.allowThis(facilities[id].totalCommitmentUSD); FHE.allow(facilities[id].totalCommitmentUSD, borrower); FHE.allow(facilities[id].totalCommitmentUSD, msg.sender);
        FHE.allowThis(facilities[id].outstandingDrawUSD); FHE.allow(facilities[id].outstandingDrawUSD, borrower);
        FHE.allowThis(facilities[id].availableUSD); FHE.allow(facilities[id].availableUSD, borrower);
        FHE.allowThis(facilities[id].spreadBps); FHE.allow(facilities[id].spreadBps, borrower);
        FHE.allowThis(facilities[id].commitmentFeeBps);
        FHE.allowThis(facilities[id].covenantScore); FHE.allow(facilities[id].covenantScore, borrower);
        FHE.allowThis(_totalCommitmentsUSD);
        emit FacilityCreated(id, borrower, facilityType);
    }

    function drawdown(
        uint256 facilityId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant returns (uint256 drawId) {
        CreditFacility storage f = facilities[facilityId];
        require(msg.sender == f.borrower, "Not borrower");
        require(f.covenantStatus == CovenantStatus.Compliant, "Covenant breach");
        euint64 amt = FHE.fromExternal(encAmount, proof);
        ebool hasCapacity = FHE.le(amt, f.availableUSD);
        euint64 drawnAmt = FHE.select(hasCapacity, amt, FHE.asEuint64(0));
        f.outstandingDrawUSD = FHE.add(f.outstandingDrawUSD, drawnAmt);
        f.availableUSD = FHE.sub(f.availableUSD, drawnAmt);
        _totalOutstandingUSD = FHE.add(_totalOutstandingUSD, drawnAmt);
        drawId = drawdownCount++;
        drawdowns[drawId] = Drawdown({
            facilityId: facilityId, borrower: msg.sender, amountUSD: drawnAmt,
            interestAccruedUSD: FHE.asEuint64(0), drawnAt: block.timestamp, repaid: false
        });
        FHE.allowThis(drawdowns[drawId].amountUSD); FHE.allow(drawdowns[drawId].amountUSD, msg.sender); FHE.allow(drawdowns[drawId].amountUSD, f.agentBank);
        FHE.allowThis(drawdowns[drawId].interestAccruedUSD);
        FHE.allowThis(f.outstandingDrawUSD); FHE.allow(f.outstandingDrawUSD, msg.sender);
        FHE.allowThis(f.availableUSD); FHE.allow(f.availableUSD, msg.sender);
        FHE.allowThis(_totalOutstandingUSD);
        emit DrawdownMade(drawId, facilityId);
    }

    function repayDrawdown(uint256 drawId) external nonReentrant {
        Drawdown storage d = drawdowns[drawId];
        require(msg.sender == d.borrower, "Not borrower");
        require(!d.repaid, "Already repaid");
        d.repaid = true;
        CreditFacility storage f = facilities[d.facilityId];
        f.outstandingDrawUSD = FHE.sub(f.outstandingDrawUSD, d.amountUSD);
        f.availableUSD = FHE.add(f.availableUSD, d.amountUSD);
        _totalOutstandingUSD = FHE.sub(_totalOutstandingUSD, d.amountUSD);
        FHE.allowThis(f.outstandingDrawUSD); FHE.allow(f.outstandingDrawUSD, msg.sender);
        FHE.allowThis(f.availableUSD); FHE.allow(f.availableUSD, msg.sender);
        FHE.allowThis(_totalOutstandingUSD);
        emit DrawdownRepaid(drawId);
    }

    function updateCovenantScore(
        uint256 facilityId,
        externalEuint8 encScore, bytes calldata proof,
        CovenantStatus newStatus
    ) external onlyAgentBank {
        CreditFacility storage f = facilities[facilityId];
        f.covenantScore = FHE.fromExternal(encScore, proof);
        f.covenantStatus = newStatus;
        FHE.allowThis(f.covenantScore);
        FHE.allow(f.covenantScore, f.borrower);
        FHE.allow(f.covenantScore, f.agentBank);
        emit CovenantUpdated(facilityId, newStatus);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalCommitmentsUSD, viewer);
        FHE.allow(_totalOutstandingUSD, viewer);
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