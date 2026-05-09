// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSovereignDebtRestructuring
/// @notice IMF-style sovereign debt restructuring with encrypted creditor
///         haircuts, NPV calculations, and voting on restructuring terms.
///         Creditor positions and voting weights are confidential.
contract EncryptedSovereignDebtRestructuring is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DebtInstrumentType { Brady, Eurobond, LocalCurrency, IMFLoan, WorldBankLoan, BilateralODA }
    enum RestructuringStatus { PreNegotiation, Negotiation, VotingOpen, VotingClosed, Approved, Rejected, Implemented }

    struct SovereignDebt {
        uint256 debtId;
        DebtInstrumentType instrumentType;
        string creditorName;
        euint64 faceValueUSD;         // encrypted outstanding principal
        euint32 couponRateBps;        // encrypted interest rate
        euint32 remainingMaturityMonths; // encrypted time to maturity
        euint64 npvUSD;               // encrypted net present value
        euint32 proposedHaircutBps;   // encrypted proposed haircut
        bool consented;
    }

    struct RestructuringProposal {
        uint256 proposalId;
        euint32 haircut_Bps;          // encrypted average haircut
        euint32 maturityExtensionMonths; // encrypted tenor extension
        euint32 couponReductionBps;   // encrypted rate reduction
        euint64 totalDebtRelief;      // encrypted total debt saved
        euint64 npvOfNewTerms;        // encrypted NPV under new terms
        RestructuringStatus status;
        uint256 votingDeadline;
        euint64 yesVoteWeight;        // encrypted yes vote weight
        euint64 noVoteWeight;         // encrypted no vote weight
        euint32 quorumThresholdBps;   // encrypted quorum required
    }

    struct CreditorVote {
        address creditor;
        uint256 proposalId;
        euint64 votingWeight;         // encrypted weight (proportional to claim)
        bool votedYes;
        bool hasVoted;
    }

    mapping(uint256 => SovereignDebt) private debts;
    mapping(uint256 => RestructuringProposal) private proposals;
    mapping(address => mapping(uint256 => CreditorVote)) private votes;
    mapping(address => bool) public isCreditor;
    mapping(address => bool) public isIMFAdvisor;

    uint256 public debtCount;
    uint256 public proposalCount;
    string public sovereignName;

    euint64 private _totalOutstandingDebt;
    euint64 private _totalDebtRelief;
    euint64 private _totalConsentingDebt;

    event DebtRegistered(uint256 indexed debtId, DebtInstrumentType instrumentType);
    event ProposalSubmitted(uint256 indexed proposalId);
    event VoteCast(address indexed creditor, uint256 proposalId);
    event ProposalResult(uint256 indexed proposalId, bool approved);
    event DebtRestructured(uint256 indexed debtId);

    modifier onlyIMF() {
        require(isIMFAdvisor[msg.sender] || msg.sender == owner(), "Not IMF advisor");
        _;
    }

    constructor(string memory _sovereignName) Ownable(msg.sender) {
        sovereignName = _sovereignName;
        _totalOutstandingDebt = FHE.asEuint64(0);
        _totalDebtRelief = FHE.asEuint64(0);
        _totalConsentingDebt = FHE.asEuint64(0);
        FHE.allowThis(_totalOutstandingDebt);
        FHE.allowThis(_totalDebtRelief);
        FHE.allowThis(_totalConsentingDebt);
        isIMFAdvisor[msg.sender] = true;
    }

    function addIMFAdvisor(address adv) external onlyOwner { isIMFAdvisor[adv] = true; }
    function registerCreditor(address cred) external onlyOwner { isCreditor[cred] = true; }

    function registerDebt(
        DebtInstrumentType instrType,
        string calldata creditorName,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint32 encCoupon, bytes calldata couponProof,
        externalEuint32 encMaturity, bytes calldata matProof
    ) external onlyIMF returns (uint256 debtId) {
        debtId = debtCount++;
        SovereignDebt storage d = debts[debtId];
        d.debtId = debtId;
        d.instrumentType = instrType;
        d.creditorName = creditorName;
        d.faceValueUSD = FHE.fromExternal(encFaceValue, fvProof);
        d.couponRateBps = FHE.fromExternal(encCoupon, couponProof);
        d.remainingMaturityMonths = FHE.fromExternal(encMaturity, matProof);
        d.npvUSD = d.faceValueUSD; // simplified
        d.proposedHaircutBps = FHE.asEuint32(0);
        d.consented = false;
        _totalOutstandingDebt = FHE.add(_totalOutstandingDebt, d.faceValueUSD);
        FHE.allowThis(d.faceValueUSD); FHE.allowThis(d.couponRateBps);
        FHE.allowThis(d.remainingMaturityMonths); FHE.allowThis(d.npvUSD);
        FHE.allowThis(d.proposedHaircutBps); FHE.allowThis(_totalOutstandingDebt);
        emit DebtRegistered(debtId, instrType);
    }

    function submitProposal(
        externalEuint32 encHaircut, bytes calldata hcProof,
        externalEuint32 encMaturityExt, bytes calldata matProof,
        externalEuint32 encCouponReduction, bytes calldata crProof,
        externalEuint64 encDebtRelief, bytes calldata drProof,
        externalEuint32 encQuorum, bytes calldata quorumProof,
        uint256 votingDeadline
    ) external onlyIMF returns (uint256 proposalId) {
        proposalId = proposalCount++;
        RestructuringProposal storage p = proposals[proposalId];
        p.proposalId = proposalId;
        p.haircut_Bps = FHE.fromExternal(encHaircut, hcProof);
        p.maturityExtensionMonths = FHE.fromExternal(encMaturityExt, matProof);
        p.couponReductionBps = FHE.fromExternal(encCouponReduction, crProof);
        p.totalDebtRelief = FHE.fromExternal(encDebtRelief, drProof);
        p.npvOfNewTerms = FHE.asEuint64(0);
        p.status = RestructuringStatus.VotingOpen;
        p.votingDeadline = votingDeadline;
        p.yesVoteWeight = FHE.asEuint64(0);
        p.noVoteWeight = FHE.asEuint64(0);
        p.quorumThresholdBps = FHE.fromExternal(encQuorum, quorumProof);
        FHE.allowThis(p.haircut_Bps); FHE.allowThis(p.maturityExtensionMonths);
        FHE.allowThis(p.couponReductionBps); FHE.allowThis(p.totalDebtRelief);
        FHE.allowThis(p.yesVoteWeight); FHE.allowThis(p.noVoteWeight);
        FHE.allowThis(p.quorumThresholdBps);
        emit ProposalSubmitted(proposalId);
    }

    function castVote(
        uint256 proposalId,
        bool voteYes,
        externalEuint64 encVoteWeight, bytes calldata proof
    ) external nonReentrant {
        require(isCreditor[msg.sender], "Not creditor");
        RestructuringProposal storage p = proposals[proposalId];
        require(p.status == RestructuringStatus.VotingOpen, "Voting not open");
        require(block.timestamp <= p.votingDeadline, "Voting ended");
        CreditorVote storage v = votes[msg.sender][proposalId];
        require(!v.hasVoted, "Already voted");
        euint64 weight = FHE.fromExternal(encVoteWeight, proof);
        v.creditor = msg.sender;
        v.proposalId = proposalId;
        v.votingWeight = weight;
        v.votedYes = voteYes;
        v.hasVoted = true;
        if (voteYes) {
            p.yesVoteWeight = FHE.add(p.yesVoteWeight, weight);
        } else {
            p.noVoteWeight = FHE.add(p.noVoteWeight, weight);
        }
        FHE.allowThis(v.votingWeight);
        FHE.allowThis(p.yesVoteWeight); FHE.allowThis(p.noVoteWeight);
        emit VoteCast(msg.sender, proposalId);
    }

    function tallyVotes(uint256 proposalId) external onlyIMF {
        RestructuringProposal storage p = proposals[proposalId];
        require(p.status == RestructuringStatus.VotingOpen, "Not open");
        p.status = RestructuringStatus.VotingClosed;
        ebool approved = FHE.gt(p.yesVoteWeight, p.noVoteWeight);
        if (FHE.isInitialized(approved)) {
            p.status = RestructuringStatus.Approved;
            _totalDebtRelief = FHE.add(_totalDebtRelief, p.totalDebtRelief);
            FHE.allowThis(_totalDebtRelief);
            emit ProposalResult(proposalId, true);
        } else {
            p.status = RestructuringStatus.Rejected;
            emit ProposalResult(proposalId, false);
        }
    }

    function allowDebtView(uint256 debtId, address viewer) external onlyIMF {
        FHE.allow(debts[debtId].faceValueUSD, viewer);
        FHE.allow(debts[debtId].proposedHaircutBps, viewer);
        FHE.allow(debts[debtId].npvUSD, viewer);
    }

    function allowRestructuringStats(address viewer) external onlyOwner {
        FHE.allow(_totalOutstandingDebt, viewer);
        FHE.allow(_totalDebtRelief, viewer);
        FHE.allow(_totalConsentingDebt, viewer);
    }
}
