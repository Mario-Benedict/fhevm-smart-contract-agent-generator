// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ConfidentialTradeFinanceLCExtended
/// @notice Encrypted letter of credit: hidden LC amounts, private trade terms,
///         confidential bank margin requirements, and encrypted document
///         compliance verification scoring.
contract ConfidentialTradeFinanceLCExtended is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum LCType { Sight, Usance, Standby, BackToBack, Revolving }
    enum LCStatus { Issued, Confirmed, Presented, Accepted, Paid, Expired, Cancelled }

    struct LetterOfCredit {
        address applicant;             // buyer
        address beneficiary;           // seller
        address issuingBank;
        address confirmingBank;
        LCType  lcType;
        string  lcRef;
        string  goodsDescription;
        euint64 lcAmountUSD;           // encrypted LC amount
        euint64 bankMarginBps;         // encrypted bank margin
        euint64 bankFeeUSD;            // encrypted bank fee
        euint64 insurancePremiumUSD;   // encrypted insurance
        euint16 documentComplianceScore; // encrypted doc score
        LCStatus status;
        uint256 issueDate;
        uint256 expiryDate;
    }

    mapping(uint256 => LetterOfCredit) private lcs;
    mapping(address => bool) public isTradeBank;

    uint256 public lcCount;
    euint64 private _totalLCVolumeUSD;
    euint64 private _totalBankFeesUSD;

    event LCIssued(uint256 indexed id, LCType lcType, address applicant, address beneficiary);
    event LCPresented(uint256 indexed id, uint256 presentedAt);
    event LCPaid(uint256 indexed id, uint256 paidAt);

    modifier onlyTradeBank() {
        require(isTradeBank[msg.sender] || msg.sender == owner(), "Not trade bank");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLCVolumeUSD = FHE.asEuint64(0);
        _totalBankFeesUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalLCVolumeUSD);
        FHE.allowThis(_totalBankFeesUSD);
        isTradeBank[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addTradeBank(address b) external onlyOwner { isTradeBank[b] = true; }

    function issueLC(
        address applicant, address beneficiary, address confirmingBank,
        LCType lcType, string calldata lcRef, string calldata goodsDescription,
        externalEuint64 encLCAmount, bytes calldata lcaProof,
        externalEuint64 encMargin,   bytes calldata mProof,
        externalEuint64 encInsurance,bytes calldata insProof,
        uint256 expiryDays
    ) external onlyTradeBank whenNotPaused returns (uint256 id) {
        euint64 lcAmount  = FHE.fromExternal(encLCAmount, lcaProof);
        euint64 margin    = FHE.fromExternal(encMargin, mProof);
        euint64 insurance = FHE.fromExternal(encInsurance, insProof);
        euint64 bankFee   = FHE.div(FHE.mul(lcAmount, margin), 10000);
        id = lcCount++;
        LetterOfCredit storage _s0 = lcs[id];
        _s0.applicant = applicant;
        _s0.beneficiary = beneficiary;
        _s0.issuingBank = msg.sender;
        _s0.confirmingBank = confirmingBank;
        _s0.lcType = lcType;
        _s0.lcRef = lcRef;
        _s0.goodsDescription = goodsDescription;
        _s0.lcAmountUSD = lcAmount;
        _s0.bankMarginBps = margin;
        _s0.bankFeeUSD = bankFee;
        _s0.insurancePremiumUSD = insurance;
        _s0.documentComplianceScore = FHE.asEuint16(0);
        _s0.status = LCStatus.Issued;
        _s0.issueDate = block.timestamp;
        _s0.expiryDate = block.timestamp + expiryDays * 1 days;
        _totalLCVolumeUSD = FHE.add(_totalLCVolumeUSD, lcAmount);
        _totalBankFeesUSD = FHE.add(_totalBankFeesUSD, bankFee);
        FHE.allowThis(lcs[id].lcAmountUSD); FHE.allow(lcs[id].lcAmountUSD, applicant); FHE.allow(lcs[id].lcAmountUSD, beneficiary);
        FHE.allowThis(lcs[id].bankMarginBps);
        FHE.allowThis(lcs[id].bankFeeUSD); FHE.allow(lcs[id].bankFeeUSD, applicant);
        FHE.allowThis(lcs[id].insurancePremiumUSD); FHE.allow(lcs[id].insurancePremiumUSD, applicant);
        FHE.allowThis(lcs[id].documentComplianceScore);
        FHE.allowThis(_totalLCVolumeUSD); FHE.allowThis(_totalBankFeesUSD);
        emit LCIssued(id, lcType, applicant, beneficiary);
    }

    function presentDocuments(uint256 lcId, externalEuint16 encDocScore, bytes calldata proof) external whenNotPaused {
        LetterOfCredit storage lc = lcs[lcId];
        require(msg.sender == lc.beneficiary && lc.status == LCStatus.Issued, "Cannot present");
        euint16 docScore = FHE.fromExternal(encDocScore, proof);
        lc.documentComplianceScore = docScore;
        lc.status = LCStatus.Presented;
        FHE.allowThis(lc.documentComplianceScore); FHE.allow(lc.documentComplianceScore, lc.issuingBank);
        emit LCPresented(lcId, block.timestamp);
    }

    function payLC(uint256 lcId) external onlyTradeBank nonReentrant {
        LetterOfCredit storage lc = lcs[lcId];
        require(lc.status == LCStatus.Presented && block.timestamp < lc.expiryDate, "Cannot pay");
        ebool docsCompliant = FHE.ge(lc.documentComplianceScore, FHE.asEuint16(7000));
        lc.status = LCStatus.Paid;
        FHE.allow(lc.lcAmountUSD, lc.beneficiary);
        emit LCPaid(lcId, block.timestamp);
    }

    function allowTradeStats(address viewer) external onlyOwner {
        FHE.allow(_totalLCVolumeUSD, viewer); FHE.allow(_totalBankFeesUSD, viewer);
    }
}