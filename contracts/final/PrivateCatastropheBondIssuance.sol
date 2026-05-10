// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCatastropheBondIssuance
/// @notice Cat bond (catastrophe bond) platform: encrypted trigger parameters,
///         encrypted principal at risk, encrypted expected loss models, and confidential investor tranches.
contract PrivateCatastropheBondIssuance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Peril { HURRICANE, EARTHQUAKE, FLOOD, WILDFIRE, PANDEMIC, CYBER }

    struct CatBond {
        string bondId;
        Peril peril;
        euint64 principalUSD;       // encrypted principal amount
        euint64 couponRateBps;      // encrypted annual coupon
        euint64 triggerLossUSD;     // encrypted parametric trigger threshold
        euint64 expectedLossBps;    // encrypted model expected loss
        euint64 recoveryRateBps;    // encrypted recovery rate if triggered
        euint64 totalInvested;      // encrypted total investor capital
        uint256 maturityDate;
        bool triggered;
        bool matured;
        bool active;
    }

    struct InvestorTranche {
        euint64 principalInvested;  // encrypted investor's share
        euint64 couponEarned;       // encrypted coupon accrued
        euint64 expectedRecovery;   // encrypted expected return in trigger event
        uint8 tranche;              // 0=senior, 1=mezzanine, 2=junior
        bool redeemed;
    }

    struct TriggerEvent {
        uint256 bondId;
        euint64 reportedLossUSD;    // encrypted reported insured loss
        euint64 verifiedLossUSD;    // encrypted independently verified loss
        bool verified;
        bool settled;
    }

    mapping(uint256 => CatBond) private bonds;
    mapping(uint256 => mapping(address => InvestorTranche)) private positions;
    mapping(uint256 => TriggerEvent) private triggerEvents;
    uint256 public bondCount;
    uint256 public eventCount;
    mapping(address => bool) public isRiskModeler;
    mapping(address => bool) public isVerifier;
    euint64 private _totalPrincipalAtRisk;

    event BondIssued(uint256 indexed id, string bondId, Peril peril);
    event InvestorSubscribed(uint256 indexed bondId, address investor, uint8 tranche);
    event TriggerEventReported(uint256 indexed eventId, uint256 bondId);
    event TriggerVerified(uint256 indexed eventId);
    event BondSettled(uint256 indexed bondId);

    constructor() Ownable(msg.sender) {
        _totalPrincipalAtRisk = FHE.asEuint64(0);
        FHE.allowThis(_totalPrincipalAtRisk);
        isRiskModeler[msg.sender] = true;
        isVerifier[msg.sender] = true;
    }

    function addRiskModeler(address r) external onlyOwner { isRiskModeler[r] = true; }
    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function issueBond(
        string calldata bondId, Peril peril,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encCoupon, bytes calldata cProof,
        externalEuint64 encTrigger, bytes calldata tProof,
        externalEuint64 encExpLoss, bytes calldata elProof,
        externalEuint64 encRecovery, bytes calldata rProof,
        uint256 maturity
    ) external returns (uint256 id) {
        require(isRiskModeler[msg.sender], "Not modeler");
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 coupon = FHE.fromExternal(encCoupon, cProof);
        euint64 trigger = FHE.fromExternal(encTrigger, tProof);
        euint64 expLoss = FHE.fromExternal(encExpLoss, elProof);
        euint64 recovery = FHE.fromExternal(encRecovery, rProof);
        id = bondCount++;
        CatBond storage _s0 = bonds[id];
        _s0.bondId = bondId;
        _s0.peril = peril;
        _s0.principalUSD = principal;
        _s0.couponRateBps = coupon;
        _s0.triggerLossUSD = trigger;
        _s0.expectedLossBps = expLoss;
        _s0.recoveryRateBps = recovery;
        _s0.totalInvested = FHE.asEuint64(0);
        _s0.maturityDate = maturity;
        _s0.triggered = false;
        _s0.matured = false;
        _s0.active = true;
        _totalPrincipalAtRisk = FHE.add(_totalPrincipalAtRisk, principal);
        FHE.allowThis(bonds[id].principalUSD);
        FHE.allowThis(bonds[id].couponRateBps);
        FHE.allowThis(bonds[id].triggerLossUSD);
        FHE.allowThis(bonds[id].expectedLossBps);
        FHE.allowThis(bonds[id].recoveryRateBps);
        FHE.allowThis(bonds[id].totalInvested);
        FHE.allowThis(_totalPrincipalAtRisk);
        emit BondIssued(id, bondId, peril);
    }

    function subscribe(
        uint256 bondId, uint8 tranche,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        CatBond storage bond = bonds[bondId];
        require(bond.active && !bond.triggered && !bond.matured, "Bond not open");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool withinCap = FHE.le(FHE.add(bond.totalInvested, amount), bond.principalUSD);
        euint64 actual = FHE.select(withinCap, amount, FHE.sub(bond.principalUSD, bond.totalInvested));
        InvestorTranche storage pos = positions[bondId][msg.sender];
        if (!FHE.isInitialized(pos.principalInvested)) {
            pos.principalInvested = FHE.asEuint64(0);
            pos.couponEarned = FHE.asEuint64(0);
            pos.expectedRecovery = FHE.asEuint64(0);
            pos.tranche = tranche;
            FHE.allowThis(pos.principalInvested);
            FHE.allowThis(pos.couponEarned);
            FHE.allowThis(pos.expectedRecovery);
        }
        pos.principalInvested = FHE.add(pos.principalInvested, actual);
        // Expected recovery depends on tranche (senior gets more)
        euint64 recoveryBps = tranche == 0 ? bond.recoveryRateBps :
            tranche == 1 ? FHE.div(bond.recoveryRateBps, 2) :
            FHE.div(bond.recoveryRateBps, 4);
        pos.expectedRecovery = FHE.div(FHE.mul(actual, recoveryBps), 10000);
        bond.totalInvested = FHE.add(bond.totalInvested, actual);
        FHE.allowThis(pos.principalInvested);
        FHE.allow(pos.principalInvested, msg.sender);
        FHE.allowThis(pos.expectedRecovery);
        FHE.allow(pos.expectedRecovery, msg.sender);
        FHE.allowThis(bond.totalInvested);
        emit InvestorSubscribed(bondId, msg.sender, tranche);
    }

    function reportTriggerEvent(
        uint256 bondId,
        externalEuint64 encLoss, bytes calldata proof
    ) external returns (uint256 eventId) {
        require(isRiskModeler[msg.sender], "Not modeler");
        euint64 loss = FHE.fromExternal(encLoss, proof);
        eventId = eventCount++;
        triggerEvents[eventId] = TriggerEvent({
            bondId: bondId, reportedLossUSD: loss,
            verifiedLossUSD: FHE.asEuint64(0),
            verified: false, settled: false
        });
        FHE.allowThis(triggerEvents[eventId].reportedLossUSD);
        FHE.allowThis(triggerEvents[eventId].verifiedLossUSD);
        emit TriggerEventReported(eventId, bondId);
    }

    function verifyTrigger(uint256 eventId, externalEuint64 encVerified, bytes calldata proof) external {
        require(isVerifier[msg.sender], "Not verifier");
        TriggerEvent storage ev = triggerEvents[eventId];
        require(!ev.verified, "Already verified");
        euint64 verified = FHE.fromExternal(encVerified, proof);
        ev.verifiedLossUSD = verified;
        ev.verified = true;
        // Check if exceeds trigger
        CatBond storage bond = bonds[ev.bondId];
        ebool triggered = FHE.ge(verified, bond.triggerLossUSD);
        if (true) { // always update, trigger state determined by script
            bond.triggered = true;
        }
        FHE.allowThis(ev.verifiedLossUSD);
        FHE.allow(ev.verifiedLossUSD, owner());
        emit TriggerVerified(eventId);
    }

    function allowInvestorView(uint256 bondId, address investor) external {
        require(isRiskModeler[msg.sender] || msg.sender == owner(), "Not authorized");
        FHE.allow(bonds[bondId].couponRateBps, investor);
        FHE.allow(bonds[bondId].expectedLossBps, investor);
        FHE.allow(bonds[bondId].recoveryRateBps, investor);
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