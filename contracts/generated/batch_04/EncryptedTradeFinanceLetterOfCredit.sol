// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedTradeFinanceLetterOfCredit
/// @notice Bank-issued letter of credit for international trade. Encrypted credit amount,
///         document compliance scores, and drawdown amounts for exporters.
contract EncryptedTradeFinanceLetterOfCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum LCType { Irrevocable, Confirmed, Standby, Revolving }
    enum LCStatus { Issued, Advised, PartiallyDrawn, FullyDrawn, Expired, Cancelled }

    struct LetterOfCredit {
        address issuingBank;
        address applicant;            // importer
        address beneficiary;          // exporter
        LCType lcType;
        string commodityDescription;
        string incoterms;             // e.g. "CIF", "FOB"
        euint64 creditAmountUSD;     // encrypted LC face value
        euint64 drawnAmountUSD;      // encrypted amount drawn
        euint64 availableAmountUSD;  // encrypted remaining balance
        euint32 documentScore;       // encrypted compliance doc score
        uint256 expiryDate;
        LCStatus status;
    }

    struct DrawdownRequest {
        uint256 lcId;
        address beneficiary;
        euint64 requestedAmountUSD; // encrypted drawdown request
        euint32 documentCompliance; // encrypted doc compliance check
        bool approved;
        uint256 submittedAt;
    }

    mapping(uint256 => LetterOfCredit) private lcs;
    mapping(uint256 => DrawdownRequest[]) private drawdowns;
    mapping(address => bool) public isBank;
    mapping(address => bool) public isTradeFinanceAuditor;

    uint256 public lcCount;
    euint64 private _totalLCValueUSD;
    euint64 private _totalDrawnUSD;

    event LCIssued(uint256 indexed id, address applicant, address beneficiary);
    event DrawdownSubmitted(uint256 indexed lcId, uint256 drawdownIndex);
    event DrawdownApproved(uint256 indexed lcId, uint256 drawdownIndex);

    modifier onlyBank() {
        require(isBank[msg.sender] || msg.sender == owner(), "Not bank");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLCValueUSD = FHE.asEuint64(0);
        _totalDrawnUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalLCValueUSD);
        FHE.allowThis(_totalDrawnUSD);
        isBank[msg.sender] = true;
    }

    function addBank(address b) external onlyOwner { isBank[b] = true; }
    function addAuditor(address a) external onlyOwner { isTradeFinanceAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function issueLC(
        address applicant,
        address beneficiary,
        LCType lcType,
        string calldata commodity,
        string calldata incoterms,
        externalEuint64 encAmount, bytes calldata aProof,
        uint256 expiryDays
    ) external onlyBank whenNotPaused returns (uint256 id) {
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        id = lcCount++;
        LetterOfCredit storage _s0 = lcs[id];
        _s0.issuingBank = msg.sender;
        _s0.applicant = applicant;
        _s0.beneficiary = beneficiary;
        _s0.lcType = lcType;
        _s0.commodityDescription = commodity;
        _s0.incoterms = incoterms;
        _s0.creditAmountUSD = amount;
        _s0.drawnAmountUSD = FHE.asEuint64(0);
        _s0.availableAmountUSD = amount;
        _s0.documentScore = FHE.asEuint32(0);
        _s0.expiryDate = block.timestamp + expiryDays * 1 days;
        _s0.status = LCStatus.Issued;
        _totalLCValueUSD = FHE.add(_totalLCValueUSD, amount);
        FHE.allowThis(lcs[id].creditAmountUSD);
        FHE.allow(lcs[id].creditAmountUSD, applicant);
        FHE.allow(lcs[id].creditAmountUSD, beneficiary);
        FHE.allowThis(lcs[id].drawnAmountUSD);
        FHE.allowThis(lcs[id].availableAmountUSD);
        FHE.allow(lcs[id].availableAmountUSD, beneficiary);
        FHE.allowThis(lcs[id].documentScore);
        FHE.allowThis(_totalLCValueUSD);
        emit LCIssued(id, applicant, beneficiary);
    }

    function submitDrawdown(
        uint256 lcId,
        externalEuint64 encRequestAmt, bytes calldata rProof,
        externalEuint32 encDocScore, bytes calldata dProof
    ) external whenNotPaused nonReentrant returns (uint256 drawdownIndex) {
        LetterOfCredit storage lc = lcs[lcId];
        require(lc.beneficiary == msg.sender, "Not beneficiary");
        require(lc.status == LCStatus.Issued || lc.status == LCStatus.PartiallyDrawn, "Cannot draw");
        require(block.timestamp < lc.expiryDate, "Expired");
        euint64 reqAmt = FHE.fromExternal(encRequestAmt, rProof);
        euint32 docScore = FHE.fromExternal(encDocScore, dProof);
        // Clamp to available
        ebool sufficient = FHE.le(reqAmt, lc.availableAmountUSD);
        euint64 actualAmt = FHE.select(sufficient, reqAmt, lc.availableAmountUSD);
        DrawdownRequest memory req = DrawdownRequest({
            lcId: lcId, beneficiary: msg.sender,
            requestedAmountUSD: actualAmt, documentCompliance: docScore,
            approved: false, submittedAt: block.timestamp
        });
        drawdowns[lcId].push(req);
        drawdownIndex = drawdowns[lcId].length - 1;
        lc.documentScore = docScore;
        FHE.allowThis(req.requestedAmountUSD);
        FHE.allow(req.requestedAmountUSD, lc.issuingBank);
        FHE.allow(req.requestedAmountUSD, msg.sender);
        FHE.allowThis(req.documentCompliance);
        FHE.allow(req.documentCompliance, lc.issuingBank);
        FHE.allowThis(lc.documentScore);
        emit DrawdownSubmitted(lcId, drawdownIndex);
    }

    function approveDrawdown(uint256 lcId, uint256 drawdownIndex) external onlyBank nonReentrant {
        LetterOfCredit storage lc = lcs[lcId];
        DrawdownRequest storage req = drawdowns[lcId][drawdownIndex];
        require(!req.approved, "Already approved");
        // Require minimum doc score of 70
        ebool docOk = FHE.ge(req.documentCompliance, FHE.asEuint32(70));
        euint64 payment = FHE.select(docOk, req.requestedAmountUSD, FHE.asEuint64(0));
        req.approved = true;
        lc.drawnAmountUSD = FHE.add(lc.drawnAmountUSD, payment);
        lc.availableAmountUSD = FHE.sub(lc.availableAmountUSD, payment);
        _totalDrawnUSD = FHE.add(_totalDrawnUSD, payment);
        lc.status = FHE.isInitialized(FHE.eq(lc.availableAmountUSD, FHE.asEuint64(0)))
            ? LCStatus.FullyDrawn : LCStatus.PartiallyDrawn;
        FHE.allowThis(lc.drawnAmountUSD);
        FHE.allow(lc.drawnAmountUSD, lc.applicant);
        FHE.allowThis(lc.availableAmountUSD);
        FHE.allow(lc.availableAmountUSD, req.beneficiary);
        FHE.allowThis(_totalDrawnUSD);
        emit DrawdownApproved(lcId, drawdownIndex);
    }

    function allowLCDetails(uint256 lcId, address viewer) external onlyBank {
        LetterOfCredit storage lc = lcs[lcId];
        FHE.allow(lc.creditAmountUSD, viewer);
        FHE.allow(lc.drawnAmountUSD, viewer);
        FHE.allow(lc.availableAmountUSD, viewer);
        FHE.allow(lc.documentScore, viewer);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalLCValueUSD, viewer);
        FHE.allow(_totalDrawnUSD, viewer);
    }
}
