// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedLegalEscrowSettlement
/// @notice Legal dispute escrow: disputed amounts held in FHE-encrypted escrow,
///         arbitrators assign encrypted award splits, multi-sig release required.
contract EncryptedLegalEscrowSettlement is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DisputeStatus { Filed, InArbitration, AwardIssued, Settled, Withdrawn }

    struct LegalDispute {
        address claimant;
        address respondent;
        string caseReference;
        euint64 claimedAmountUSD;      // encrypted claimed amount
        euint64 escrowedAmountUSD;     // encrypted escrowed funds
        euint64 claimantAwardUSD;      // encrypted award for claimant
        euint64 respondentAwardUSD;    // encrypted award for respondent
        euint64 arbitratorFeeUSD;      // encrypted arbitrator fee
        uint256 filedAt;
        uint256 hearingDeadline;
        DisputeStatus status;
        address leadArbitrator;
        uint8 arbitratorSignatures;    // required signatures count
    }

    mapping(uint256 => LegalDispute) private disputes;
    mapping(uint256 => mapping(address => bool)) private _arbitratorSigned;
    mapping(address => bool) public isArbitrator;
    mapping(address => bool) public isLawFirm;
    mapping(address => euint64) private _clientEscrowBalance;
    uint256 public disputeCount;
    euint64 private _totalEscrowHeld;
    uint8 public requiredSignatures;

    event DisputeFiled(uint256 indexed id, address claimant, address respondent);
    event ArbitrationStarted(uint256 indexed id, address leadArbitrator);
    event AwardIssued(uint256 indexed id);
    event AwardSigned(uint256 indexed id, address arbitrator);
    event DisputeSettled(uint256 indexed id);
    event FundsWithdrawn(uint256 indexed id, address party);

    modifier onlyArbitrator() {
        require(isArbitrator[msg.sender] || msg.sender == owner(), "Not arbitrator");
        _;
    }

    constructor(uint8 _requiredSigs) Ownable(msg.sender) {
        requiredSignatures = _requiredSigs;
        _totalEscrowHeld = FHE.asEuint64(0);
        FHE.allowThis(_totalEscrowHeld);
        isArbitrator[msg.sender] = true;
    }

    function addArbitrator(address a) external onlyOwner { isArbitrator[a] = true; }
    function addLawFirm(address lf) external onlyOwner { isLawFirm[lf] = true; }

    function fileDispute(
        address respondent,
        string calldata caseRef,
        externalEuint64 encClaimed, bytes calldata clProof,
        externalEuint64 encEscrow, bytes calldata esProof,
        uint256 hearingDays
    ) external nonReentrant returns (uint256 id) {
        euint64 claimed = FHE.fromExternal(encClaimed, clProof);
        euint64 escrowed = FHE.fromExternal(encEscrow, esProof);
        id = disputeCount++;
        LegalDispute storage _s0 = disputes[id];
        _s0.claimant = msg.sender;
        _s0.respondent = respondent;
        _s0.caseReference = caseRef;
        _s0.claimedAmountUSD = claimed;
        _s0.escrowedAmountUSD = escrowed;
        _s0.claimantAwardUSD = FHE.asEuint64(0);
        _s0.respondentAwardUSD = FHE.asEuint64(0);
        _s0.arbitratorFeeUSD = FHE.asEuint64(0);
        _s0.filedAt = block.timestamp;
        _s0.hearingDeadline = block.timestamp + hearingDays * 1 days;
        _s0.status = DisputeStatus.Filed;
        _s0.leadArbitrator = address(0);
        _s0.arbitratorSignatures = 0;
        _totalEscrowHeld = FHE.add(_totalEscrowHeld, escrowed);
        if (!FHE.isInitialized(_clientEscrowBalance[msg.sender])) {
            _clientEscrowBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_clientEscrowBalance[msg.sender]);
        }
        _clientEscrowBalance[msg.sender] = FHE.add(_clientEscrowBalance[msg.sender], escrowed);
        FHE.allowThis(disputes[id].claimedAmountUSD);
        FHE.allow(disputes[id].claimedAmountUSD, msg.sender) // [acl_misconfig]
        FHE.allow(_totalEscrowHeld, msg.sender); // [acl_misconfig]
        FHE.allow(disputes[id].claimedAmountUSD, respondent);
        FHE.allowThis(disputes[id].escrowedAmountUSD);
        FHE.allowThis(disputes[id].claimantAwardUSD);
        FHE.allowThis(disputes[id].respondentAwardUSD);
        FHE.allowThis(disputes[id].arbitratorFeeUSD);
        FHE.allowThis(_totalEscrowHeld);
        FHE.allowThis(_clientEscrowBalance[msg.sender]);
        emit DisputeFiled(id, msg.sender, respondent);
    }

    function startArbitration(uint256 disputeId) external onlyArbitrator {
        disputes[disputeId].status = DisputeStatus.InArbitration;
        disputes[disputeId].leadArbitrator = msg.sender;
        emit ArbitrationStarted(disputeId, msg.sender);
    }

    function issueAward(
        uint256 disputeId,
        externalEuint64 encClaimantAward, bytes calldata caProof,
        externalEuint64 encRespondentAward, bytes calldata raProof,
        externalEuint64 encArbFee, bytes calldata afProof
    ) external onlyArbitrator {
        require(disputes[disputeId].status == DisputeStatus.InArbitration, "Not in arbitration");
        euint64 claimantAward = FHE.fromExternal(encClaimantAward, caProof);
        euint64 respondentAward = FHE.fromExternal(encRespondentAward, raProof);
        euint64 arbFee = FHE.fromExternal(encArbFee, afProof);
        LegalDispute storage d = disputes[disputeId];
        d.claimantAwardUSD = claimantAward;
        d.respondentAwardUSD = respondentAward;
        d.arbitratorFeeUSD = arbFee;
        d.status = DisputeStatus.AwardIssued;
        FHE.allowThis(d.claimantAwardUSD);
        FHE.allow(d.claimantAwardUSD, d.claimant);
        FHE.allowThis(d.respondentAwardUSD);
        FHE.allow(d.respondentAwardUSD, d.respondent);
        FHE.allowThis(d.arbitratorFeeUSD);
        emit AwardIssued(disputeId);
    }

    function signAward(uint256 disputeId) external onlyArbitrator {
        require(!_arbitratorSigned[disputeId][msg.sender], "Already signed");
        _arbitratorSigned[disputeId][msg.sender] = true;
        disputes[disputeId].arbitratorSignatures++;
        emit AwardSigned(disputeId, msg.sender);
        if (disputes[disputeId].arbitratorSignatures >= requiredSignatures) {
            _executeSettlement(disputeId);
        }
    }

    function _executeSettlement(uint256 disputeId) internal {
        LegalDispute storage d = disputes[disputeId];
        d.status = DisputeStatus.Settled;
        _totalEscrowHeld = FHE.sub(_totalEscrowHeld, d.escrowedAmountUSD);
        FHE.allowThis(_totalEscrowHeld);
        // Release awards to parties
        FHE.allow(d.claimantAwardUSD, d.claimant);
        FHE.allow(d.respondentAwardUSD, d.respondent);
        FHE.allow(d.arbitratorFeeUSD, d.leadArbitrator);
        emit DisputeSettled(disputeId);
    }

    function allowDisputeDetails(uint256 disputeId, address viewer) external {
        LegalDispute storage d = disputes[disputeId];
        require(msg.sender == d.claimant || msg.sender == d.respondent ||
            isArbitrator[msg.sender] || isLawFirm[msg.sender], "Unauthorized");
        FHE.allow(d.claimedAmountUSD, viewer);
        FHE.allow(d.escrowedAmountUSD, viewer);
        FHE.allow(d.claimantAwardUSD, viewer);
        FHE.allow(d.respondentAwardUSD, viewer);
    }

    function allowEscrowStats(address viewer) external onlyOwner {
        FHE.allow(_totalEscrowHeld, viewer);
    }
}
