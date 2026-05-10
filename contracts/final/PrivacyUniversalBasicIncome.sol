// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivacyUniversalBasicIncome
/// @notice UBI distribution system where recipient eligibility scores and
///         payment amounts are encrypted based on confidential income verification.
///         The system ensures means-testing without exposing financial data publicly.
contract PrivacyUniversalBasicIncome is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Recipient {
        euint64 monthlyIncome;      // encrypted verified income
        euint64 ubiAmount;          // encrypted calculated UBI payment
        euint8 eligibilityScore;    // encrypted (0-100): 100=most eligible
        euint8 householdSize;       // encrypted
        euint64 totalReceived;
        uint256 nextClaimDate;
        bool enrolled;
        bool verified;
    }

    struct UBIPeriod {
        uint256 periodNumber;
        uint256 startDate;
        euint64 totalBudget;
        euint64 amountDistributed;
        euint64 maxPerRecipient;
        euint8 incomeThreshold;   // encrypted: max income to qualify
        bool active;
        bool closed;
    }

    mapping(address => Recipient) private recipients;
    address[] public recipientList;
    mapping(uint256 => UBIPeriod) private periods;
    uint256 public periodCount;
    mapping(uint256 => mapping(address => bool)) private hasClaimed;
    mapping(address => bool) public isSocialWorker;

    event RecipientEnrolled(address indexed r);
    event UBIPeriodCreated(uint256 indexed id);
    event UBIClaimed(uint256 indexed periodId, address recipient);

    constructor() Ownable(msg.sender) {}

    function addSocialWorker(address sw) external onlyOwner { isSocialWorker[sw] = true; }

    function enroll(
        externalEuint64 encIncome, bytes calldata iProof,
        externalEuint8 encHousehold, bytes calldata hProof
    ) external {
        require(!recipients[msg.sender].enrolled, "Already enrolled");
        euint64 income = FHE.fromExternal(encIncome, iProof);
        euint8 household = FHE.fromExternal(encHousehold, hProof);
        recipients[msg.sender].monthlyIncome = income;
        recipients[msg.sender].householdSize = household;
        recipients[msg.sender].eligibilityScore = FHE.asEuint8(0);
        recipients[msg.sender].ubiAmount = FHE.asEuint64(0);
        recipients[msg.sender].totalReceived = FHE.asEuint64(0);
        recipients[msg.sender].enrolled = true;
        FHE.allowThis(recipients[msg.sender].monthlyIncome);
        FHE.allow(recipients[msg.sender].monthlyIncome, msg.sender);
        FHE.allowThis(recipients[msg.sender].householdSize);
        FHE.allow(recipients[msg.sender].householdSize, msg.sender);
        FHE.allowThis(recipients[msg.sender].eligibilityScore);
        FHE.allow(recipients[msg.sender].eligibilityScore, msg.sender);
        FHE.allowThis(recipients[msg.sender].ubiAmount);
        FHE.allow(recipients[msg.sender].ubiAmount, msg.sender);
        FHE.allowThis(recipients[msg.sender].totalReceived);
        FHE.allow(recipients[msg.sender].totalReceived, msg.sender);
        recipientList.push(msg.sender);
        emit RecipientEnrolled(msg.sender);
    }

    function verifyAndSetUBI(
        address recipient,
        externalEuint8 encEligibility, bytes calldata eProof,
        externalEuint64 encUBIAmount, bytes calldata uProof
    ) external {
        require(isSocialWorker[msg.sender], "Not social worker");
        require(recipients[recipient].enrolled, "Not enrolled");
        recipients[recipient].eligibilityScore = FHE.fromExternal(encEligibility, eProof);
        recipients[recipient].ubiAmount = FHE.fromExternal(encUBIAmount, uProof);
        recipients[recipient].verified = true;
        FHE.allowThis(recipients[recipient].eligibilityScore);
        FHE.allow(recipients[recipient].eligibilityScore, recipient);
        FHE.allowThis(recipients[recipient].ubiAmount);
        FHE.allow(recipients[recipient].ubiAmount, recipient);
    }

    function createUBIPeriod(
        uint256 durationDays,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encMaxPerRecipient, bytes calldata mProof,
        externalEuint8 encIncomeThreshold, bytes calldata tProof
    ) external onlyOwner returns (uint256 id) {
        id = periodCount++;
        periods[id].periodNumber = id;
        periods[id].startDate = block.timestamp;
        periods[id].totalBudget = FHE.fromExternal(encBudget, bProof);
        periods[id].maxPerRecipient = FHE.fromExternal(encMaxPerRecipient, mProof);
        periods[id].incomeThreshold = FHE.fromExternal(encIncomeThreshold, tProof);
        periods[id].amountDistributed = FHE.asEuint64(0);
        periods[id].active = true;
        FHE.allowThis(periods[id].totalBudget);
        FHE.allowThis(periods[id].maxPerRecipient);
        FHE.allowThis(periods[id].incomeThreshold);
        FHE.allowThis(periods[id].amountDistributed);
        emit UBIPeriodCreated(id);
    }

    function claimUBI(uint256 periodId) external nonReentrant {
        Recipient storage r = recipients[msg.sender];
        UBIPeriod storage p = periods[periodId];
        require(r.enrolled && r.verified, "Not eligible");
        require(p.active && !hasClaimed[periodId][msg.sender], "Cannot claim");
        require(block.timestamp >= r.nextClaimDate, "Too early");
        // Check income threshold eligibility
        ebool incomeOk = FHE.ge(p.incomeThreshold, r.eligibilityScore);
        ebool budgetOk = FHE.ge(FHE.sub(p.totalBudget, p.amountDistributed), r.ubiAmount);
        ebool eligible = FHE.and(incomeOk, budgetOk);
        euint64 payment = FHE.select(eligible, r.ubiAmount, FHE.asEuint64(0));
        // Cap to maxPerRecipient
        ebool withinCap = FHE.le(payment, p.maxPerRecipient);
        payment = FHE.select(withinCap, payment, p.maxPerRecipient);
        r.totalReceived = FHE.add(r.totalReceived, payment);
        p.amountDistributed = FHE.add(p.amountDistributed, payment);
        hasClaimed[periodId][msg.sender] = true;
        r.nextClaimDate = block.timestamp + 30 days;
        FHE.allow(payment, msg.sender);
        FHE.allowThis(r.totalReceived);
        FHE.allow(r.totalReceived, msg.sender);
        FHE.allowThis(p.amountDistributed);
        emit UBIClaimed(periodId, msg.sender);
    }

    function closePeriod(uint256 periodId) external onlyOwner {
        periods[periodId].active = false;
        periods[periodId].closed = true;
        FHE.allow(periods[periodId].totalBudget, owner());
        FHE.allow(periods[periodId].amountDistributed, owner());
    }

    function allowRecipientData(address viewer) external {
        FHE.allow(recipients[msg.sender].eligibilityScore, viewer);
        FHE.allow(recipients[msg.sender].ubiAmount, viewer);
        FHE.allow(recipients[msg.sender].totalReceived, viewer);
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