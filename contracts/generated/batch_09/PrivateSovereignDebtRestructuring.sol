// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateSovereignDebtRestructuring
/// @notice Encrypted sovereign debt restructuring platform for distressed nations.
///         Creditor haircut proposals, GDP-linked warrants, and debt-to-equity swaps
///         are negotiated with encrypted notional amounts and recovery rates.
contract PrivateSovereignDebtRestructuring is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum BondClass { SENIOR_SECURED, SENIOR_UNSECURED, SUBORDINATED, GDP_LINKED, BRADY_BOND }
    enum RestructuringStatus { NEGOTIATION, VOTING, AGREED, FAILED, IMPLEMENTED }

    struct SovereignBond {
        string issuingCountry;
        string isinCode;
        BondClass bondClass;
        euint64 outstandingPrincipal; // encrypted face value outstanding (USD millions)
        euint64 couponRateBps;        // encrypted annual coupon (bps)
        euint64 proposedHaircutBps;   // encrypted proposed haircut percentage
        euint64 recoveryValueUSD;     // encrypted estimated recovery
        euint32 maturityYear;
        uint256 issuanceDate;
        bool inDefault;
    }

    struct CreditorPosition {
        euint64 notionalHeld;         // encrypted face value held
        euint64 purchasePricePaid;    // encrypted cost basis
        euint64 marketValueCurrent;   // encrypted current mark-to-market
        euint64 acceptedRecovery;     // encrypted agreed recovery amount
        euint8  hairccutConsentBps;   // encrypted haircut consented to
        bool votedYes;
        bool participated;
    }

    struct RestructuringProposal {
        euint64 totalDebtOutstanding;  // encrypted total sovereign debt
        euint64 proposedNewDebt;       // encrypted post-haircut debt
        euint64 gdpWarrantValue;       // encrypted GDP-linked upside
        euint64 cashPaymentUSD;        // encrypted cash sweetener
        euint32 extensionYears;
        uint256 votingDeadline;
        uint256 yesVoteWeight;
        uint256 totalVoteWeight;
        RestructuringStatus status;
    }

    mapping(uint256 => SovereignBond) private bonds;
    mapping(address => mapping(uint256 => CreditorPosition)) private creditorPositions;
    mapping(uint256 => RestructuringProposal) private proposals;
    mapping(address => bool) public isIMFOfficer;
    mapping(address => bool) public isAccreditedCreditor;
    uint256 public bondCount;
    uint256 public proposalCount;
    euint64 private _totalSovereignDebtManaged;

    event BondRegistered(uint256 indexed bondId, string country, BondClass bClass);
    event CreditorRegistered(address indexed creditor, uint256 bondId);
    event ProposalCreated(uint256 indexed proposalId);
    event CreditorVoted(address indexed creditor, uint256 proposalId, bool yes);
    event RestructuringAgreed(uint256 indexed proposalId);
    event RestructuringFailed(uint256 indexed proposalId);

    constructor() Ownable(msg.sender) {
        _totalSovereignDebtManaged = FHE.asEuint64(0);
        FHE.allowThis(_totalSovereignDebtManaged);
        isIMFOfficer[msg.sender] = true;
    }

    function addIMFOfficer(address officer) external onlyOwner { isIMFOfficer[officer] = true; }

    function registerCreditor(address creditor) external {
        require(isIMFOfficer[msg.sender], "Not IMF officer");
        isAccreditedCreditor[creditor] = true;
    }

    function registerBond(
        string calldata country,
        string calldata isin,
        BondClass bClass,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encCoupon,    bytes calldata cProof,
        externalEuint32 encMaturity,  bytes calldata mProof
    ) external returns (uint256 bondId) {
        require(isIMFOfficer[msg.sender], "Not IMF officer");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 coupon    = FHE.fromExternal(encCoupon, cProof);
        euint32 maturity  = FHE.fromExternal(encMaturity, mProof);
        bondId = bondCount++;
        bonds[bondId].issuingCountry = country;
        bonds[bondId].isinCode = isin;
        bonds[bondId].bondClass = bClass;
        bonds[bondId].outstandingPrincipal = principal;
        bonds[bondId].couponRateBps = coupon;
        bonds[bondId].proposedHaircutBps = FHE.asEuint64(0);
        bonds[bondId].recoveryValueUSD = FHE.asEuint64(0);
        bonds[bondId].maturityYear = maturity;
        bonds[bondId].issuanceDate = block.timestamp;
        bonds[bondId].inDefault = false;
        _totalSovereignDebtManaged = FHE.add(_totalSovereignDebtManaged, principal);
        FHE.allowThis(bonds[bondId].outstandingPrincipal);
        FHE.allowThis(bonds[bondId].couponRateBps);
        FHE.allowThis(bonds[bondId].proposedHaircutBps);
        FHE.allowThis(bonds[bondId].recoveryValueUSD);
        FHE.allowThis(bonds[bondId].maturityYear);
        FHE.allowThis(_totalSovereignDebtManaged);
        emit BondRegistered(bondId, country, bClass);
    }

    function registerCreditorPosition(
        uint256 bondId,
        externalEuint64 encNotional, bytes calldata nProof,
        externalEuint64 encCostBasis, bytes calldata cbProof
    ) external {
        require(isAccreditedCreditor[msg.sender], "Not accredited");
        euint64 notional  = FHE.fromExternal(encNotional, nProof);
        euint64 costBasis = FHE.fromExternal(encCostBasis, cbProof);
        creditorPositions[msg.sender][bondId] = CreditorPosition({
            notionalHeld: notional,
            purchasePricePaid: costBasis,
            marketValueCurrent: FHE.asEuint64(0),
            acceptedRecovery: FHE.asEuint64(0),
            hairccutConsentBps: FHE.asEuint8(0),
            votedYes: false,
            participated: false
        });
        FHE.allowThis(creditorPositions[msg.sender][bondId].notionalHeld);
        FHE.allow(creditorPositions[msg.sender][bondId].notionalHeld, msg.sender);
        FHE.allowThis(creditorPositions[msg.sender][bondId].purchasePricePaid);
        FHE.allow(creditorPositions[msg.sender][bondId].purchasePricePaid, msg.sender);
        FHE.allowThis(creditorPositions[msg.sender][bondId].marketValueCurrent);
        FHE.allowThis(creditorPositions[msg.sender][bondId].acceptedRecovery);
        FHE.allowThis(creditorPositions[msg.sender][bondId].hairccutConsentBps);
        emit CreditorRegistered(msg.sender, bondId);
    }

    function createRestructuringProposal(
        externalEuint64 encTotalDebt,  bytes calldata tdProof,
        externalEuint64 encNewDebt,    bytes calldata ndProof,
        externalEuint64 encGDPWarrant, bytes calldata gdpProof,
        externalEuint64 encCash,       bytes calldata cashProof,
        uint256 extensionYears,
        uint256 votingDuration
    ) external returns (uint256 propId) {
        require(isIMFOfficer[msg.sender], "Not IMF officer");
        euint64 totalDebt = FHE.fromExternal(encTotalDebt, tdProof);
        euint64 newDebt   = FHE.fromExternal(encNewDebt, ndProof);
        euint64 gdpWar    = FHE.fromExternal(encGDPWarrant, gdpProof);
        euint64 cash      = FHE.fromExternal(encCash, cashProof);
        propId = proposalCount++;
        proposals[propId].totalDebtOutstanding = totalDebt;
        proposals[propId].proposedNewDebt = newDebt;
        proposals[propId].gdpWarrantValue = gdpWar;
        proposals[propId].cashPaymentUSD = cash;
        proposals[propId].extensionYears = FHE.asEuint32(uint32(extensionYears));
        proposals[propId].votingDeadline = block.timestamp + votingDuration;
        proposals[propId].yesVoteWeight = 0;
        proposals[propId].totalVoteWeight = 0;
        proposals[propId].status = RestructuringStatus.VOTING;
        FHE.allowThis(proposals[propId].totalDebtOutstanding);
        FHE.allowThis(proposals[propId].proposedNewDebt);
        FHE.allowThis(proposals[propId].gdpWarrantValue);
        FHE.allowThis(proposals[propId].cashPaymentUSD);
        FHE.allowThis(proposals[propId].extensionYears);
        emit ProposalCreated(propId);
    }

    function voteOnProposal(uint256 propId, uint256 bondId, bool voteYes) external nonReentrant {
        require(isAccreditedCreditor[msg.sender], "Not creditor");
        require(block.timestamp < proposals[propId].votingDeadline, "Voting closed");
        require(!creditorPositions[msg.sender][bondId].participated, "Already voted");
        creditorPositions[msg.sender][bondId].participated = true;
        creditorPositions[msg.sender][bondId].votedYes = voteYes;
        proposals[propId].totalVoteWeight += 1;
        if (voteYes) proposals[propId].yesVoteWeight += 1;
        emit CreditorVoted(msg.sender, propId, voteYes);
    }

    function finalizeProposal(uint256 propId) external {
        require(isIMFOfficer[msg.sender], "Not IMF officer");
        require(block.timestamp >= proposals[propId].votingDeadline, "Voting not ended");
        RestructuringProposal storage prop = proposals[propId];
        if (prop.totalVoteWeight > 0 && prop.yesVoteWeight * 100 / prop.totalVoteWeight >= 75) {
            prop.status = RestructuringStatus.AGREED;
            emit RestructuringAgreed(propId);
        } else {
            prop.status = RestructuringStatus.FAILED;
            emit RestructuringFailed(propId);
        }
    }

    function allowDebtView(address viewer) external onlyOwner {
        FHE.allow(_totalSovereignDebtManaged, viewer);
    }
}
