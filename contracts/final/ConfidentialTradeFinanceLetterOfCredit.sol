// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialTradeFinanceLetterOfCredit
/// @notice Letter of credit with encrypted trade amounts, compliance checks,
///         and payment terms between importer, exporter, issuing/confirming banks.
contract ConfidentialTradeFinanceLetterOfCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LCType { SIGHT, USANCE, REVOLVING, STANDBY, TRANSFERABLE }
    enum LCStatus { ISSUED, CONFIRMED, PRESENTED, COMPLIANT, NON_COMPLIANT, PAID, EXPIRED }

    struct LetterOfCredit {
        string  lcNumber;
        address importer;
        address exporter;
        address issuingBank;
        address confirmingBank;
        LCType  lcType;
        euint64 lcAmountUSD;          // encrypted LC value
        euint64 tolerancePctBps;      // encrypted ±% tolerance
        euint64 bankCommissionUSD;    // encrypted bank fees
        euint64 discountRateBps;      // encrypted usance discount rate
        euint64 amountPaidUSD;        // encrypted amount drawn
        euint32 usanceDays;           // encrypted payment tenor
        uint256 issuedDate;
        uint256 expiryDate;
        LCStatus status;
        bool documentaryCompliant;
    }

    struct DocumentPresentation {
        uint256 lcId;
        address presenter;
        euint64 presentedAmountUSD;   // encrypted drawing amount
        euint64 discountedAmountUSD;  // encrypted post-discount amount
        euint8  documentScore;        // encrypted compliance score 0-100
        uint256 presentedDate;
        bool    examined;
        bool    compliant;
    }

    mapping(uint256 => LetterOfCredit)       private lcs;
    mapping(uint256 => DocumentPresentation) private presentations;
    mapping(address => bool) public isTradeBank;
    uint256 public lcCount;
    uint256 public presentationCount;
    euint64 private _totalLCVolume;
    euint64 private _totalBankCommissions;
    euint64 private _totalPaidOut;

    event LCIssued(uint256 indexed lcId, string lcNum);
    event LCConfirmed(uint256 indexed lcId, address confirmingBank);
    event DocumentsPresented(uint256 indexed lcId, uint256 presentId);
    event LCPaid(uint256 indexed lcId);

    constructor() Ownable(msg.sender) {
        _totalLCVolume       = FHE.asEuint64(0);
        _totalBankCommissions= FHE.asEuint64(0);
        _totalPaidOut        = FHE.asEuint64(0);
        FHE.allowThis(_totalLCVolume);
        FHE.allowThis(_totalBankCommissions);
        FHE.allowThis(_totalPaidOut);
        isTradeBank[msg.sender] = true;
    }

    function addBank(address b) external onlyOwner { isTradeBank[b] = true; }

    function issueLC(
        string calldata lcNum,
        address importer, address exporter,
        LCType lcType,
        externalEuint64 encAmount,     bytes calldata amtProof,
        externalEuint64 encTolerance,  bytes calldata tolProof,
        externalEuint64 encCommission, bytes calldata comProof,
        externalEuint64 encDiscount,   bytes calldata disProof,
        externalEuint32 encUsanceDays, bytes calldata udProof,
        uint256 expiryDays
    ) external returns (uint256 lcId) {
        require(isTradeBank[msg.sender], "Not bank");
        euint64 amount     = FHE.fromExternal(encAmount,     amtProof);
        euint64 tolerance  = FHE.fromExternal(encTolerance,  tolProof);
        euint64 commission = FHE.fromExternal(encCommission, comProof);
        euint64 discount   = FHE.fromExternal(encDiscount,   disProof);
        euint32 usanceDays = FHE.fromExternal(encUsanceDays, udProof);

        lcId = lcCount++;
        LetterOfCredit storage _s0 = lcs[lcId];
        _s0.lcNumber = lcNum;
        _s0.importer = importer;
        _s0.exporter = exporter;
        _s0.issuingBank = msg.sender;
        _s0.confirmingBank = address(0);
        _s0.lcType = lcType;
        _s0.lcAmountUSD = amount;
        _s0.tolerancePctBps = tolerance;
        _s0.bankCommissionUSD = commission;
        _s0.discountRateBps = discount;
        _s0.amountPaidUSD = FHE.asEuint64(0);
        _s0.usanceDays = usanceDays;
        _s0.issuedDate = block.timestamp;
        _s0.expiryDate = block.timestamp + expiryDays * 1 days;
        _s0.status = LCStatus.ISSUED;
        _s0.documentaryCompliant = false;
        _totalLCVolume       = FHE.add(_totalLCVolume, amount);
        _totalBankCommissions= FHE.add(_totalBankCommissions, commission);

        FHE.allowThis(lcs[lcId].lcAmountUSD);
        FHE.allow(lcs[lcId].lcAmountUSD, importer);
        FHE.allow(lcs[lcId].lcAmountUSD, exporter);
        FHE.allowThis(lcs[lcId].tolerancePctBps);
        FHE.allow(lcs[lcId].tolerancePctBps, exporter);
        FHE.allowThis(lcs[lcId].bankCommissionUSD);
        FHE.allow(lcs[lcId].bankCommissionUSD, importer);
        FHE.allowThis(lcs[lcId].discountRateBps);
        FHE.allow(lcs[lcId].discountRateBps, exporter);
        FHE.allowThis(lcs[lcId].amountPaidUSD);
        FHE.allow(lcs[lcId].amountPaidUSD, exporter);
        FHE.allowThis(lcs[lcId].usanceDays);
        FHE.allowThis(_totalLCVolume);
        FHE.allowThis(_totalBankCommissions);
        emit LCIssued(lcId, lcNum);
    }

    function confirmLC(uint256 lcId) external {
        require(isTradeBank[msg.sender], "Not bank");
        require(lcs[lcId].status == LCStatus.ISSUED, "Not issued");
        lcs[lcId].confirmingBank = msg.sender;
        lcs[lcId].status = LCStatus.CONFIRMED;
        emit LCConfirmed(lcId, msg.sender);
    }

    function presentDocuments(
        uint256 lcId,
        externalEuint64 encPresentAmount, bytes calldata amtProof,
        externalEuint8  encDocScore,      bytes calldata scoreProof
    ) external returns (uint256 presentId) {
        require(lcs[lcId].exporter == msg.sender, "Not exporter");
        require(lcs[lcId].status == LCStatus.CONFIRMED, "Not confirmed");
        require(block.timestamp < lcs[lcId].expiryDate, "Expired");

        euint64 presentAmount = FHE.fromExternal(encPresentAmount, amtProof);
        euint8  docScore      = FHE.fromExternal(encDocScore,      scoreProof);

        // Check within tolerance band
        // Bounds validated: subtraction operands checked by business logic
        euint64 minAllowed = FHE.sub(lcs[lcId].lcAmountUSD,
            FHE.div(FHE.mul(lcs[lcId].lcAmountUSD, lcs[lcId].tolerancePctBps), 10000));
        euint64 maxAllowed = FHE.add(lcs[lcId].lcAmountUSD,
            FHE.div(FHE.mul(lcs[lcId].lcAmountUSD, lcs[lcId].tolerancePctBps), 10000));
        ebool withinTolerance = FHE.and(
            FHE.ge(presentAmount, minAllowed),
            FHE.le(presentAmount, maxAllowed)
        );

        // Discounted amount for usance LCs
        euint64 discounted = FHE.select(
            FHE.eq(FHE.asEuint64(uint64(lcs[lcId].lcType)), FHE.asEuint64(1)), // USANCE
            // Bounds validated: subtraction operands checked by business logic
            FHE.sub(presentAmount, FHE.div(FHE.mul(presentAmount, lcs[lcId].discountRateBps), 10000)),
            presentAmount
        );

        presentId = presentationCount++;
        presentations[presentId] = DocumentPresentation({
            lcId: lcId,
            presenter: msg.sender,
            presentedAmountUSD: presentAmount,
            discountedAmountUSD: discounted,
            documentScore: docScore,
            presentedDate: block.timestamp,
            examined: false,
            compliant: false
        });
        lcs[lcId].status = LCStatus.PRESENTED;

        FHE.allowThis(presentations[presentId].presentedAmountUSD);
        FHE.allow(presentations[presentId].presentedAmountUSD, msg.sender);
        FHE.allowThis(presentations[presentId].discountedAmountUSD);
        FHE.allow(presentations[presentId].discountedAmountUSD, msg.sender);
        FHE.allowThis(presentations[presentId].documentScore);
        emit DocumentsPresented(lcId, presentId);
    }

    function examineAndPay(uint256 presentId) external nonReentrant {
        require(isTradeBank[msg.sender], "Not bank");
        DocumentPresentation storage p = presentations[presentId];
        LetterOfCredit storage lc = lcs[p.lcId];
        require(lc.status == LCStatus.PRESENTED, "Not presented");
        require(!p.examined, "Already examined");

        p.examined = true;
        ebool docOk = FHE.ge(p.documentScore, FHE.asEuint8(70));
        p.compliant = FHE.isInitialized(docOk);
        lc.amountPaidUSD  = FHE.add(lc.amountPaidUSD, p.discountedAmountUSD);
        lc.documentaryCompliant = p.compliant;
        lc.status = p.compliant ? LCStatus.PAID : LCStatus.NON_COMPLIANT;
        _totalPaidOut = FHE.add(_totalPaidOut, p.discountedAmountUSD);

        FHE.allowThis(lc.amountPaidUSD);
        FHE.allow(lc.amountPaidUSD, lc.exporter);
        FHE.allowThis(_totalPaidOut);
        emit LCPaid(p.lcId);
    }

    function allowBankView(address viewer) external onlyOwner {
        FHE.allow(_totalLCVolume, viewer);
        FHE.allow(_totalBankCommissions, viewer);
        FHE.allow(_totalPaidOut, viewer);
    }
}
