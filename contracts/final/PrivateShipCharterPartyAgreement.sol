// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateShipCharterPartyAgreement
/// @notice Encrypted voyage charter contracts including freight rates, deadweight
///         cargo calculations, laytime counters, demurrage accruals, and
///         confidential arbitration awards for maritime disputes.
contract PrivateShipCharterPartyAgreement is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CharterType { VOYAGE, TIME, BAREBOAT, CONTRACT_OF_AFFREIGHTMENT }
    enum CargoType { BULK_DRY, LIQUID_BULK, BREAKBULK, CONTAINER, REEFER, CHEMICAL }
    enum CharterStatus { NEGOTIATING, CONFIRMED, LOADING, IN_VOYAGE, DISCHARGING, COMPLETED, DISPUTED }

    struct CharterParty {
        address shipowner;
        address charterer;
        CharterType charterType;
        CargoType cargoType;
        CharterStatus status;
        euint64 freightRate;         // encrypted USD per metric tonne
        euint64 cargoQuantityMT;     // encrypted cargo in metric tonnes
        euint64 totalFreight;        // encrypted total freight payable
        euint64 laytimeAllowedHours; // encrypted allowed laytime in hours
        euint64 laytimeUsedHours;    // encrypted actual laytime used
        euint64 demurrageRatePerHour;// encrypted demurrage rate
        euint64 demurrageAccrued;    // encrypted total demurrage owed
        euint64 despatchEarned;      // encrypted despatch earned (if early)
        euint64 deadweightTonnage;   // encrypted vessel DWT
        euint64 hireRatePerDay;      // encrypted time-charter daily rate
        uint256 laycanStart;
        uint256 laycanEnd;
        uint256 completedAt;
        bool freightPrepaid;
    }

    struct ArbitrationCase {
        bytes32 charterPartyId;
        address claimant;
        address respondent;
        euint64 claimAmount;         // encrypted claim value
        euint64 awardAmount;         // encrypted arbitration award
        euint64 legalCosts;          // encrypted legal costs allocated
        bool resolved;
        uint256 filedAt;
    }

    mapping(bytes32 => CharterParty) private charterParties;
    mapping(bytes32 => ArbitrationCase) private arbitrations;
    mapping(address => euint64) private shipownerEarnings;    // encrypted accumulated earnings
    mapping(address => euint64) private chartererLiabilities; // encrypted total liabilities
    mapping(address => bool) public registeredBroker;

    euint64 private _totalFreightVolume;    // encrypted total market freight
    euint64 private _platformBrokerageAccrued; // encrypted total brokerage

    event CharterCreated(bytes32 indexed cpId, address shipowner, address charterer, CharterType ctype);
    event LaytimeStarted(bytes32 indexed cpId);
    event DemurrageAccrued(bytes32 indexed cpId);
    event CharterCompleted(bytes32 indexed cpId);
    event ArbitrationFiled(bytes32 indexed caseId, bytes32 indexed cpId);
    event AwardIssued(bytes32 indexed caseId);

    constructor() Ownable(msg.sender) {
        _totalFreightVolume = FHE.asEuint64(0);
        _platformBrokerageAccrued = FHE.asEuint64(0);
        FHE.allowThis(_totalFreightVolume);
        FHE.allowThis(_platformBrokerageAccrued);
    }

    function registerBroker(address broker) external onlyOwner {
        registeredBroker[broker] = true;
    }

    function createCharterParty(
        address charterer,
        CharterType charterType,
        CargoType cargoType,
        externalEuint64 encFreightRate, bytes calldata frProof,
        externalEuint64 encCargoQty, bytes calldata cqProof,
        externalEuint64 encLaytime, bytes calldata ltProof,
        externalEuint64 encDemurrageRate, bytes calldata drProof,
        externalEuint64 encDWT, bytes calldata dwtProof,
        uint256 laycanStart,
        uint256 laycanEnd,
        bool freightPrepaid
    ) external nonReentrant returns (bytes32 cpId) {
        require(laycanEnd > laycanStart, "Invalid laycan");

        euint64 freightRate = FHE.fromExternal(encFreightRate, frProof);
        euint64 cargoQty = FHE.fromExternal(encCargoQty, cqProof);
        euint64 laytime = FHE.fromExternal(encLaytime, ltProof);
        euint64 demurrageRate = FHE.fromExternal(encDemurrageRate, drProof);
        euint64 dwt = FHE.fromExternal(encDWT, dwtProof);
        euint64 totalFreight = FHE.mul(freightRate, cargoQty);

        cpId = keccak256(abi.encodePacked(msg.sender, charterer, laycanStart, block.timestamp));

        CharterParty storage cp = charterParties[cpId];
        cp.shipowner = msg.sender;
        cp.charterer = charterer;
        cp.charterType = charterType;
        cp.cargoType = cargoType;
        cp.status = CharterStatus.CONFIRMED;
        cp.freightRate = freightRate;
        cp.cargoQuantityMT = cargoQty;
        cp.totalFreight = totalFreight;
        cp.laytimeAllowedHours = laytime;
        cp.laytimeUsedHours = FHE.asEuint64(0);
        cp.demurrageRatePerHour = demurrageRate;
        cp.demurrageAccrued = FHE.asEuint64(0);
        cp.despatchEarned = FHE.asEuint64(0);
        cp.deadweightTonnage = dwt;
        cp.hireRatePerDay = FHE.asEuint64(0);
        cp.laycanStart = laycanStart;
        cp.laycanEnd = laycanEnd;
        cp.completedAt = 0;
        cp.freightPrepaid = freightPrepaid;

        FHE.allowThis(freightRate);
        FHE.allow(freightRate, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFreightVolume, msg.sender); // [acl_misconfig]
        FHE.allow(_platformBrokerageAccrued, msg.sender); // [acl_misconfig]
        FHE.allow(freightRate, charterer);
        FHE.allowThis(cargoQty);
        FHE.allow(cargoQty, msg.sender);
        FHE.allow(cargoQty, charterer);
        FHE.allowThis(totalFreight);
        FHE.allow(totalFreight, msg.sender);
        FHE.allow(totalFreight, charterer);
        FHE.allowThis(laytime);
        FHE.allow(laytime, msg.sender);
        FHE.allow(laytime, charterer);
        FHE.allowThis(demurrageRate);
        FHE.allowThis(dwt);
        FHE.allowThis(charterParties[cpId].laytimeUsedHours);
        FHE.allowThis(charterParties[cpId].demurrageAccrued);
        FHE.allowThis(charterParties[cpId].despatchEarned);
        FHE.allowThis(charterParties[cpId].hireRatePerDay);

        _totalFreightVolume = FHE.add(_totalFreightVolume, totalFreight);
        FHE.allowThis(_totalFreightVolume);

        emit CharterCreated(cpId, msg.sender, charterer, charterType);
    }

    function updateLaytime(
        bytes32 cpId,
        externalEuint64 encHoursUsed, bytes calldata huProof
    ) external {
        CharterParty storage cp = charterParties[cpId];
        require(msg.sender == cp.shipowner || msg.sender == cp.charterer, "Not party");
        require(cp.status == CharterStatus.LOADING || cp.status == CharterStatus.DISCHARGING, "Wrong status");

        euint64 hoursUsed = FHE.fromExternal(encHoursUsed, huProof);
        cp.laytimeUsedHours = FHE.add(cp.laytimeUsedHours, hoursUsed);

        ebool overLaytime = FHE.gt(cp.laytimeUsedHours, cp.laytimeAllowedHours);
        euint64 excessHours = FHE.select(overLaytime,
            FHE.sub(cp.laytimeUsedHours, cp.laytimeAllowedHours),
            FHE.asEuint64(0));
        cp.demurrageAccrued = FHE.mul(excessHours, cp.demurrageRatePerHour);

        euint64 savedHours = FHE.select(overLaytime,
            FHE.asEuint64(0),
            FHE.sub(cp.laytimeAllowedHours, cp.laytimeUsedHours));
        euint64 despatchRate = FHE.div(cp.demurrageRatePerHour, 2);
        cp.despatchEarned = FHE.mul(savedHours, despatchRate);

        FHE.allowThis(cp.laytimeUsedHours);
        FHE.allow(cp.laytimeUsedHours, cp.shipowner);
        FHE.allow(cp.laytimeUsedHours, cp.charterer);
        FHE.allowThis(cp.demurrageAccrued);
        FHE.allow(cp.demurrageAccrued, cp.shipowner);
        FHE.allow(cp.demurrageAccrued, cp.charterer);
        FHE.allowThis(cp.despatchEarned);
        FHE.allow(cp.despatchEarned, cp.charterer);

        emit DemurrageAccrued(cpId);
    }

    function completeCharter(bytes32 cpId) external {
        CharterParty storage cp = charterParties[cpId];
        require(msg.sender == cp.shipowner, "Only shipowner");
        cp.status = CharterStatus.COMPLETED;
        cp.completedAt = block.timestamp;

        // Shipowner earns freight net of any despatch owed
        euint64 netEarnings = FHE.add(cp.totalFreight, cp.demurrageAccrued);
        netEarnings = FHE.sub(netEarnings, cp.despatchEarned);

        shipownerEarnings[cp.shipowner] = FHE.add(shipownerEarnings[cp.shipowner], netEarnings);
        chartererLiabilities[cp.charterer] = FHE.add(chartererLiabilities[cp.charterer], cp.demurrageAccrued);

        euint64 brokerage = FHE.div(FHE.mul(cp.totalFreight, 125), 10000); // 1.25%
        _platformBrokerageAccrued = FHE.add(_platformBrokerageAccrued, brokerage);

        FHE.allowThis(shipownerEarnings[cp.shipowner]);
        FHE.allow(shipownerEarnings[cp.shipowner], cp.shipowner);
        FHE.allowThis(chartererLiabilities[cp.charterer]);
        FHE.allow(chartererLiabilities[cp.charterer], cp.charterer);
        FHE.allowThis(_platformBrokerageAccrued);

        emit CharterCompleted(cpId);
    }

    function fileArbitration(
        bytes32 cpId,
        externalEuint64 encClaimAmount, bytes calldata caProof
    ) external nonReentrant returns (bytes32 caseId) {
        CharterParty storage cp = charterParties[cpId];
        require(msg.sender == cp.shipowner || msg.sender == cp.charterer, "Not party");
        require(cp.status == CharterStatus.COMPLETED, "Charter not completed");

        euint64 claimAmount = FHE.fromExternal(encClaimAmount, caProof);
        address respondent = msg.sender == cp.shipowner ? cp.charterer : cp.shipowner;
        caseId = keccak256(abi.encodePacked(cpId, msg.sender, block.timestamp));

        arbitrations[caseId] = ArbitrationCase({
            charterPartyId: cpId,
            claimant: msg.sender,
            respondent: respondent,
            claimAmount: claimAmount,
            awardAmount: FHE.asEuint64(0),
            legalCosts: FHE.asEuint64(0),
            resolved: false,
            filedAt: block.timestamp
        });
        cp.status = CharterStatus.DISPUTED;

        FHE.allowThis(claimAmount);
        FHE.allow(claimAmount, msg.sender);
        FHE.allow(claimAmount, respondent);
        FHE.allowThis(arbitrations[caseId].awardAmount);
        FHE.allowThis(arbitrations[caseId].legalCosts);

        emit ArbitrationFiled(caseId, cpId);
    }

    function issueAward(
        bytes32 caseId,
        externalEuint64 encAwardAmount, bytes calldata aaProof,
        externalEuint64 encLegalCosts, bytes calldata lcProof
    ) external onlyOwner {
        ArbitrationCase storage arb = arbitrations[caseId];
        require(!arb.resolved, "Already resolved");
        euint64 award = FHE.fromExternal(encAwardAmount, aaProof);
        euint64 legalCosts = FHE.fromExternal(encLegalCosts, lcProof);
        arb.awardAmount = award;
        arb.legalCosts = legalCosts;
        arb.resolved = true;
        FHE.allowThis(award);
        FHE.allow(award, arb.claimant);
        FHE.allow(award, arb.respondent);
        FHE.allowThis(legalCosts);
        FHE.allow(legalCosts, arb.claimant);
        FHE.allow(legalCosts, arb.respondent);
        emit AwardIssued(caseId);
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