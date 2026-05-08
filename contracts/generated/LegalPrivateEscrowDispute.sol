// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LegalPrivateEscrowDispute
/// @notice Legal escrow with encrypted evidence weights and dispute resolution.
///         Arbitrators score encrypted evidence submissions; weighted verdicts
///         determine fund release without revealing individual evidence valuations.
contract LegalPrivateEscrowDispute is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DisputeStatus { None, Opened, UnderArbitration, Resolved }

    struct EscrowAgreement {
        address depositor;
        address beneficiary;
        euint64 amount;
        euint64 arbitrationFee;
        string description;
        uint256 releaseDate;
        bool released;
        bool disputed;
        DisputeStatus disputeStatus;
    }

    struct DisputeCase {
        uint256 escrowId;
        address claimant;
        string claimDescription;
        euint8 depositorEvidenceWeight;  // encrypted
        euint8 beneficiaryEvidenceWeight; // encrypted
        euint64 proposedSettlement;      // encrypted
        address assignedArbitrator;
        bool resolved;
        bool depositorWon;
    }

    mapping(uint256 => EscrowAgreement) private escrows;
    uint256 public escrowCount;
    mapping(uint256 => DisputeCase) private disputes;
    uint256 public disputeCount;
    mapping(address => bool) public isArbitrator;
    euint64 private _arbitrationFeeRate;

    event EscrowCreated(uint256 indexed id, address depositor, address beneficiary);
    event FundsReleased(uint256 indexed id);
    event DisputeOpened(uint256 indexed escrowId, uint256 disputeId);
    event DisputeResolved(uint256 indexed disputeId, bool depositorWon);

    constructor(externalEuint64 encFeeRate, bytes memory proof) Ownable(msg.sender) {
        _arbitrationFeeRate = FHE.fromExternal(encFeeRate, proof);
        FHE.allowThis(_arbitrationFeeRate);
    }

    function addArbitrator(address a) external onlyOwner { isArbitrator[a] = true; }

    function createEscrow(
        address beneficiary, uint256 releaseDays, string calldata desc,
        externalEuint64 encAmount, bytes calldata aProof
    ) external nonReentrant returns (uint256 id) {
        id = escrowCount++;
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 arbFee = FHE.div(FHE.mul(amount, _arbitrationFeeRate), 10000);
        escrows[id] = EscrowAgreement({
            depositor: msg.sender, beneficiary: beneficiary,
            amount: FHE.sub(amount, arbFee),
            arbitrationFee: arbFee,
            description: desc,
            releaseDate: block.timestamp + releaseDays * 1 days,
            released: false, disputed: false,
            disputeStatus: DisputeStatus.None
        });
        FHE.allowThis(escrows[id].amount);
        FHE.allow(escrows[id].amount, msg.sender);
        FHE.allow(escrows[id].amount, beneficiary);
        FHE.allowThis(escrows[id].arbitrationFee);
        emit EscrowCreated(id, msg.sender, beneficiary);
    }

    function releaseFunds(uint256 escrowId) external {
        EscrowAgreement storage e = escrows[escrowId];
        require(msg.sender == e.depositor || (block.timestamp >= e.releaseDate), "Cannot release");
        require(!e.released && !e.disputed, "Not releasable");
        e.released = true;
        FHE.allow(e.amount, e.beneficiary);
        emit FundsReleased(escrowId);
    }

    function openDispute(
        uint256 escrowId, string calldata claim,
        externalEuint64 encSettlement, bytes calldata sProof
    ) external returns (uint256 id) {
        EscrowAgreement storage e = escrows[escrowId];
        require(msg.sender == e.depositor || msg.sender == e.beneficiary, "Not party");
        require(!e.released && !e.disputed, "Cannot dispute");
        e.disputed = true;
        e.disputeStatus = DisputeStatus.Opened;
        id = disputeCount++;
        euint64 proposedSettlement = FHE.fromExternal(encSettlement, sProof);
        disputes[id] = DisputeCase({
            escrowId: escrowId, claimant: msg.sender, claimDescription: claim,
            depositorEvidenceWeight: FHE.asEuint8(0),
            beneficiaryEvidenceWeight: FHE.asEuint8(0),
            proposedSettlement: proposedSettlement,
            assignedArbitrator: address(0),
            resolved: false, depositorWon: false
        });
        FHE.allowThis(disputes[id].depositorEvidenceWeight);
        FHE.allowThis(disputes[id].beneficiaryEvidenceWeight);
        FHE.allowThis(disputes[id].proposedSettlement);
        emit DisputeOpened(escrowId, id);
    }

    function assignArbitrator(uint256 disputeId, address arbitrator) external onlyOwner {
        require(isArbitrator[arbitrator], "Not arbitrator");
        disputes[disputeId].assignedArbitrator = arbitrator;
        escrows[disputes[disputeId].escrowId].disputeStatus = DisputeStatus.UnderArbitration;
        FHE.allow(disputes[disputeId].proposedSettlement, arbitrator);
    }

    function submitEvidence(
        uint256 disputeId, bool isDepositorEvidence,
        externalEuint8 encWeight, bytes calldata proof
    ) external {
        DisputeCase storage d = disputes[disputeId];
        require(d.assignedArbitrator == msg.sender, "Not arbitrator");
        euint8 weight = FHE.fromExternal(encWeight, proof);
        if (isDepositorEvidence) {
            d.depositorEvidenceWeight = FHE.add(d.depositorEvidenceWeight, weight);
            FHE.allowThis(d.depositorEvidenceWeight);
        } else {
            d.beneficiaryEvidenceWeight = FHE.add(d.beneficiaryEvidenceWeight, weight);
            FHE.allowThis(d.beneficiaryEvidenceWeight);
        }
    }

    function resolveDispute(uint256 disputeId) external nonReentrant {
        DisputeCase storage d = disputes[disputeId];
        require(d.assignedArbitrator == msg.sender && !d.resolved, "Cannot resolve");
        d.resolved = true;
        EscrowAgreement storage e = escrows[d.escrowId];
        e.disputeStatus = DisputeStatus.Resolved;
        ebool depositorWins = FHE.gt(d.depositorEvidenceWeight, d.beneficiaryEvidenceWeight);
        d.depositorWon = FHE.isInitialized(depositorWins);
        if (d.depositorWon) {
            FHE.allow(e.amount, e.depositor);
        } else {
            FHE.allow(e.amount, e.beneficiary);
        }
        FHE.allow(e.arbitrationFee, msg.sender); // Arbitrator gets fee
        emit DisputeResolved(disputeId, d.depositorWon);
    }
}
