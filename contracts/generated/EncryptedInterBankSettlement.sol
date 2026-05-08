// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedInterBankSettlement
/// @notice Real-time gross settlement (RTGS) system between financial institutions.
///         Encrypted nostro/vostro balances, confidential bilateral netting,
///         and private intraday liquidity facility draws.
contract EncryptedInterBankSettlement is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum SettlementStatus { PENDING, SETTLED, REJECTED, NETTED }

    struct BankAccount {
        euint64 nostroBalance;       // encrypted balance in counterparty's books
        euint64 vostroBalance;       // encrypted balance this bank holds for others
        euint64 intradayFacility;    // encrypted central bank intraday credit line
        euint64 facilityUsed;        // encrypted amount of facility drawn
        euint64 dailySettledAmount;  // encrypted cumulative daily settled
        bool registered;
        bool suspended;
    }

    struct SettlementInstruction {
        address sendingBank;
        address receivingBank;
        euint64 amount;              // encrypted settlement amount
        euint64 fxRateBps;           // encrypted FX rate (if cross-currency)
        bytes32 referenceId;
        SettlementStatus status;
        uint256 submittedAt;
        uint256 settledAt;
    }

    struct NettingSet {
        address[] participants;
        euint64 totalGross;          // encrypted gross obligations
        euint64 totalNet;            // encrypted net settlement obligations
        bool computed;
    }

    mapping(address => BankAccount) private banks;
    mapping(uint256 => SettlementInstruction) private instructions;
    mapping(uint256 => NettingSet) private nettingSets;
    mapping(address => bool) public isCentralBank;
    mapping(address => bool) public isParticipant;

    uint256 public instructionCount;
    uint256 public nettingSetCount;
    euint64 private _systemDailyVolume;
    euint64 private _systemNettingRatioBps; // encrypted efficiency ratio

    event BankRegistered(address indexed bank);
    event InstructionSubmitted(uint256 indexed id, address from, address to);
    event InstructionSettled(uint256 indexed id);
    event InstructionRejected(uint256 indexed id);
    event NettingSetCreated(uint256 indexed id);
    event FacilityDrawn(address indexed bank);

    constructor() Ownable(msg.sender) {
        _systemDailyVolume = FHE.asEuint64(0);
        _systemNettingRatioBps = FHE.asEuint64(0);
        FHE.allowThis(_systemDailyVolume);
        FHE.allowThis(_systemNettingRatioBps);
        isCentralBank[msg.sender] = true;
    }

    modifier onlyCentralBank() { require(isCentralBank[msg.sender], "Not central bank"); _; }

    function registerBank(
        address bank,
        externalEuint64 encNostro, bytes calldata nProof,
        externalEuint64 encFacility, bytes calldata fProof
    ) external onlyCentralBank {
        require(!banks[bank].registered, "Already registered");
        BankAccount storage b = banks[bank];
        b.nostroBalance = FHE.fromExternal(encNostro, nProof);
        b.vostroBalance = FHE.asEuint64(0);
        b.intradayFacility = FHE.fromExternal(encFacility, fProof);
        b.facilityUsed = FHE.asEuint64(0);
        b.dailySettledAmount = FHE.asEuint64(0);
        b.registered = true;
        FHE.allowThis(b.nostroBalance);
        FHE.allow(b.nostroBalance, bank);
        FHE.allowThis(b.vostroBalance);
        FHE.allow(b.vostroBalance, bank);
        FHE.allowThis(b.intradayFacility);
        FHE.allow(b.intradayFacility, bank);
        FHE.allowThis(b.facilityUsed);
        FHE.allow(b.facilityUsed, bank);
        FHE.allowThis(b.dailySettledAmount);
        isParticipant[bank] = true;
        emit BankRegistered(bank);
    }

    function submitInstruction(
        address to,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encFXRate, bytes calldata fxProof,
        bytes32 referenceId
    ) external nonReentrant returns (uint256 id) {
        require(banks[msg.sender].registered && !banks[msg.sender].suspended, "Sending bank invalid");
        require(banks[to].registered && !banks[to].suspended, "Receiving bank invalid");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 fxRate = FHE.fromExternal(encFXRate, fxProof);
        id = instructionCount++;
        SettlementInstruction storage si = instructions[id];
        si.sendingBank = msg.sender;
        si.receivingBank = to;
        si.amount = amount;
        si.fxRateBps = fxRate;
        si.referenceId = referenceId;
        si.status = SettlementStatus.PENDING;
        si.submittedAt = block.timestamp;
        FHE.allowThis(si.amount);
        FHE.allow(si.amount, msg.sender);
        FHE.allow(si.amount, to);
        FHE.allowThis(si.fxRateBps);
        emit InstructionSubmitted(id, msg.sender, to);
    }

    function settleInstruction(uint256 id) external nonReentrant onlyCentralBank {
        SettlementInstruction storage si = instructions[id];
        require(si.status == SettlementStatus.PENDING, "Not pending");
        BankAccount storage sender = banks[si.sendingBank];
        BankAccount storage receiver = banks[si.receivingBank];
        // Check if sender has sufficient funds (nostro balance + available facility)
        euint64 availableFunds = FHE.add(sender.nostroBalance,
            FHE.sub(sender.intradayFacility, sender.facilityUsed));
        ebool canSettle = FHE.ge(availableFunds, si.amount);
        // If cannot settle from own funds, draw from intraday facility
        euint64 facilityDraw = FHE.select(
            FHE.and(canSettle, FHE.gt(si.amount, sender.nostroBalance)),
            FHE.sub(si.amount, sender.nostroBalance),
            FHE.asEuint64(0));
        euint64 nostroDebit = FHE.select(canSettle,
            FHE.select(FHE.le(si.amount, sender.nostroBalance), si.amount, sender.nostroBalance),
            FHE.asEuint64(0));
        sender.nostroBalance = FHE.sub(sender.nostroBalance, nostroDebit);
        sender.facilityUsed = FHE.add(sender.facilityUsed, facilityDraw);
        receiver.nostroBalance = FHE.add(receiver.nostroBalance, FHE.select(canSettle, si.amount, FHE.asEuint64(0)));
        sender.dailySettledAmount = FHE.add(sender.dailySettledAmount, FHE.select(canSettle, si.amount, FHE.asEuint64(0)));
        _systemDailyVolume = FHE.add(_systemDailyVolume, FHE.select(canSettle, si.amount, FHE.asEuint64(0)));
        si.status = FHE.decrypt(canSettle) ? SettlementStatus.SETTLED : SettlementStatus.REJECTED;
        si.settledAt = block.timestamp;
        FHE.allowThis(sender.nostroBalance);
        FHE.allow(sender.nostroBalance, si.sendingBank);
        FHE.allowThis(sender.facilityUsed);
        FHE.allow(sender.facilityUsed, si.sendingBank);
        FHE.allowThis(receiver.nostroBalance);
        FHE.allow(receiver.nostroBalance, si.receivingBank);
        FHE.allowThis(_systemDailyVolume);
        if (FHE.decrypt(canSettle)) {
            emit InstructionSettled(id);
        } else {
            emit InstructionRejected(id);
        }
    }

    function drawIntradayFacility(
        externalEuint64 encDrawAmount, bytes calldata dProof
    ) external {
        BankAccount storage b = banks[msg.sender];
        require(b.registered, "Not registered");
        euint64 draw = FHE.fromExternal(encDrawAmount, dProof);
        euint64 available = FHE.sub(b.intradayFacility, b.facilityUsed);
        ebool hasFacility = FHE.ge(available, draw);
        euint64 actualDraw = FHE.select(hasFacility, draw, available);
        b.facilityUsed = FHE.add(b.facilityUsed, actualDraw);
        b.nostroBalance = FHE.add(b.nostroBalance, actualDraw);
        FHE.allowThis(b.facilityUsed);
        FHE.allow(b.facilityUsed, msg.sender);
        FHE.allowThis(b.nostroBalance);
        FHE.allow(b.nostroBalance, msg.sender);
        emit FacilityDrawn(msg.sender);
    }

    function allowSystemStats(address overseer) external onlyCentralBank {
        FHE.allow(_systemDailyVolume, overseer);
        FHE.allow(_systemNettingRatioBps, overseer);
    }

    function addCentralBank(address cb) external onlyOwner { isCentralBank[cb] = true; }
    function suspendBank(address bank) external onlyCentralBank { banks[bank].suspended = true; }
}
