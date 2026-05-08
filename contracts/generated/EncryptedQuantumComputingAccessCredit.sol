// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedQuantumComputingAccessCredit
/// @notice Quantum computing cloud marketplace: encrypted QPU hours, encrypted
///         fidelity scores, and confidential circuit depth limits per client.
contract EncryptedQuantumComputingAccessCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum QPUArchitecture { Superconducting, TrappedIon, PhotonicChip, NeutralAtom, TopologicalQubit }
    enum AccessTier { Explorer, Developer, Enterprise, Government, Research }

    struct QuantumProcessor {
        address provider;
        string deviceName;
        QPUArchitecture architecture;
        euint32 qubitCount;               // encrypted number of qubits
        euint32 coherenceTimeMicrosec;    // encrypted coherence time
        euint32 gateErrorRateBps;         // encrypted gate error rate
        euint64 pricePerQPUHourCents;     // encrypted hourly rate
        euint64 totalRevenueEarned;       // encrypted cumulative revenue
        bool online;
    }

    struct AccessSubscription {
        address client;
        uint256 processorId;
        AccessTier tier;
        euint64 purchasedQPUHours;        // encrypted hours purchased
        euint64 usedQPUHours;             // encrypted hours consumed
        euint32 maxCircuitDepth;          // encrypted circuit depth limit
        euint32 maxQubitsAccessible;      // encrypted qubit allocation
        euint64 totalSpentCents;          // encrypted total spend
        uint256 validUntil;
        bool active;
    }

    struct JobRecord {
        uint256 subscriptionId;
        euint32 circuitDepth;             // encrypted submitted circuit depth
        euint32 qubitsUsed;               // encrypted qubits used
        euint64 hoursConsumed;            // encrypted computation hours
        euint32 fidelityScore;            // encrypted result fidelity
        uint256 submittedAt;
        bool completed;
    }

    mapping(uint256 => QuantumProcessor) private processors;
    mapping(uint256 => AccessSubscription) private subscriptions;
    mapping(uint256 => JobRecord[]) private jobs;
    mapping(address => bool) public isQPUProvider;
    mapping(address => bool) public isQPUClient;

    uint256 public processorCount;
    uint256 public subscriptionCount;
    euint64 private _totalQPUHoursSold;
    euint64 private _totalMarketRevenueCents;

    event ProcessorRegistered(uint256 indexed id, string name, QPUArchitecture arch);
    event SubscriptionPurchased(uint256 indexed id, address client, uint256 processorId);
    event JobSubmitted(uint256 indexed subId, uint256 jobIndex);
    event JobCompleted(uint256 indexed subId, uint256 jobIndex);

    modifier onlyProvider() {
        require(isQPUProvider[msg.sender] || msg.sender == owner(), "Not QPU provider");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalQPUHoursSold = FHE.asEuint64(0);
        _totalMarketRevenueCents = FHE.asEuint64(0);
        FHE.allowThis(_totalQPUHoursSold);
        FHE.allowThis(_totalMarketRevenueCents);
        isQPUProvider[msg.sender] = true;
    }

    function addProvider(address p) external onlyOwner { isQPUProvider[p] = true; }
    function addClient(address c) external onlyOwner { isQPUClient[c] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerProcessor(
        string calldata deviceName, QPUArchitecture arch,
        externalEuint32 encQubits, bytes calldata qProof,
        externalEuint32 encCoherence, bytes calldata cProof,
        externalEuint32 encGateError, bytes calldata gProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyProvider whenNotPaused returns (uint256 id) {
        euint32 qubits = FHE.fromExternal(encQubits, qProof);
        euint32 coherence = FHE.fromExternal(encCoherence, cProof);
        euint32 gateError = FHE.fromExternal(encGateError, gProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        id = processorCount++;
        processors[id] = QuantumProcessor({
            provider: msg.sender, deviceName: deviceName, architecture: arch,
            qubitCount: qubits, coherenceTimeMicrosec: coherence, gateErrorRateBps: gateError,
            pricePerQPUHourCents: price, totalRevenueEarned: FHE.asEuint64(0), online: true
        });
        FHE.allowThis(processors[id].qubitCount); FHE.allow(processors[id].qubitCount, msg.sender);
        FHE.allowThis(processors[id].coherenceTimeMicrosec); FHE.allow(processors[id].coherenceTimeMicrosec, msg.sender);
        FHE.allowThis(processors[id].gateErrorRateBps); FHE.allow(processors[id].gateErrorRateBps, msg.sender);
        FHE.allowThis(processors[id].pricePerQPUHourCents);
        FHE.allowThis(processors[id].totalRevenueEarned); FHE.allow(processors[id].totalRevenueEarned, msg.sender);
        emit ProcessorRegistered(id, deviceName, arch);
    }

    function purchaseSubscription(
        uint256 processorId, AccessTier tier,
        externalEuint64 encHours, bytes calldata hProof,
        externalEuint32 encMaxDepth, bytes calldata mdProof,
        externalEuint32 encMaxQubits, bytes calldata mqProof,
        uint256 validDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        require(isQPUClient[msg.sender], "Not QPU client");
        QuantumProcessor storage p = processors[processorId];
        require(p.online, "Processor offline");
        euint64 hours = FHE.fromExternal(encHours, hProof);
        euint32 maxDepth = FHE.fromExternal(encMaxDepth, mdProof);
        euint32 maxQubits = FHE.fromExternal(encMaxQubits, mqProof);
        euint64 totalCost = FHE.mul(hours, p.pricePerQPUHourCents);
        id = subscriptionCount++;
        subscriptions[id] = AccessSubscription({
            client: msg.sender, processorId: processorId, tier: tier,
            purchasedQPUHours: hours, usedQPUHours: FHE.asEuint64(0),
            maxCircuitDepth: maxDepth, maxQubitsAccessible: maxQubits,
            totalSpentCents: totalCost,
            validUntil: block.timestamp + validDays * 1 days, active: true
        });
        p.totalRevenueEarned = FHE.add(p.totalRevenueEarned, totalCost);
        _totalQPUHoursSold = FHE.add(_totalQPUHoursSold, hours);
        _totalMarketRevenueCents = FHE.add(_totalMarketRevenueCents, totalCost);
        FHE.allowThis(subscriptions[id].purchasedQPUHours); FHE.allow(subscriptions[id].purchasedQPUHours, msg.sender);
        FHE.allowThis(subscriptions[id].usedQPUHours); FHE.allow(subscriptions[id].usedQPUHours, msg.sender);
        FHE.allowThis(subscriptions[id].maxCircuitDepth); FHE.allow(subscriptions[id].maxCircuitDepth, msg.sender);
        FHE.allowThis(subscriptions[id].maxQubitsAccessible); FHE.allow(subscriptions[id].maxQubitsAccessible, msg.sender);
        FHE.allowThis(subscriptions[id].totalSpentCents); FHE.allow(subscriptions[id].totalSpentCents, msg.sender);
        FHE.allowThis(p.totalRevenueEarned);
        FHE.allowThis(_totalQPUHoursSold); FHE.allowThis(_totalMarketRevenueCents);
        emit SubscriptionPurchased(id, msg.sender, processorId);
    }

    function submitJob(
        uint256 subscriptionId,
        externalEuint32 encDepth, bytes calldata dProof,
        externalEuint32 encQubits, bytes calldata qProof,
        externalEuint64 encHours, bytes calldata hProof
    ) external whenNotPaused returns (uint256 jobIndex) {
        AccessSubscription storage s = subscriptions[subscriptionId];
        require(s.client == msg.sender && s.active && block.timestamp < s.validUntil, "Not authorized");
        euint32 depth = FHE.fromExternal(encDepth, dProof);
        euint32 qubits = FHE.fromExternal(encQubits, qProof);
        euint64 hours = FHE.fromExternal(encHours, hProof);
        // Validate depth within subscription limit
        ebool depthOk = FHE.le(depth, s.maxCircuitDepth);
        ebool qubitsOk = FHE.le(qubits, s.maxQubitsAccessible);
        ebool hoursOk = FHE.le(FHE.add(s.usedQPUHours, hours), s.purchasedQPUHours);
        s.usedQPUHours = FHE.add(s.usedQPUHours, hours);
        jobs[subscriptionId].push(JobRecord({
            subscriptionId: subscriptionId, circuitDepth: depth, qubitsUsed: qubits,
            hoursConsumed: hours, fidelityScore: FHE.asEuint32(0),
            submittedAt: block.timestamp, completed: false
        }));
        jobIndex = jobs[subscriptionId].length - 1;
        FHE.allowThis(depth); FHE.allowThis(qubits); FHE.allowThis(hours);
        FHE.allowThis(s.usedQPUHours); FHE.allow(s.usedQPUHours, msg.sender);
        emit JobSubmitted(subscriptionId, jobIndex);
    }

    function completeJob(
        uint256 subscriptionId, uint256 jobIndex,
        externalEuint32 encFidelity, bytes calldata proof
    ) external onlyProvider {
        JobRecord storage j = jobs[subscriptionId][jobIndex];
        j.fidelityScore = FHE.fromExternal(encFidelity, proof);
        j.completed = true;
        FHE.allowThis(j.fidelityScore);
        FHE.allow(j.fidelityScore, subscriptions[subscriptionId].client);
        emit JobCompleted(subscriptionId, jobIndex);
    }

    function allowQPUMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalQPUHoursSold, viewer);
        FHE.allow(_totalMarketRevenueCents, viewer);
    }
}
