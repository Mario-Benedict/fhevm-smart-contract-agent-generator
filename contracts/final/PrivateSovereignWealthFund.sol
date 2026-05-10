// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSovereignWealthFund
/// @notice Sovereign wealth fund with encrypted AUM per asset class, encrypted allocation targets,
///         encrypted performance benchmarks, and confidential rebalancing instructions.
contract PrivateSovereignWealthFund is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetClass { EQUITY, FIXED_INCOME, REAL_ESTATE, INFRASTRUCTURE, COMMODITIES, ALTERNATIVES }

    struct AllocationSlice {
        euint64 targetBps;         // encrypted target allocation in basis points
        euint64 currentValueUSD;   // encrypted current market value
        euint64 unrealisedPnL;     // encrypted unrealised profit/loss
        euint64 benchmarkReturn;   // encrypted benchmark return bps
        euint64 actualReturn;      // encrypted actual return bps
        uint256 lastRebalanceTime;
    }

    struct FundManager {
        euint64 managementFeeBps;  // encrypted annual fee
        euint64 performanceFeeBps; // encrypted performance fee
        euint64 aumManaged;        // encrypted AUM under management
        euint64 cumulativeFeesPaid;
        bool active;
    }

    struct RebalanceOrder {
        AssetClass fromClass;
        AssetClass toClass;
        euint64 amountUSD;          // encrypted amount to rebalance
        bool executed;
        uint256 createdAt;
        address authorizedBy;
    }

    mapping(AssetClass => AllocationSlice) private allocations;
    mapping(address => FundManager) private managers;
    mapping(uint256 => RebalanceOrder) private rebalanceOrders;
    euint64 private _totalAUM;
    euint64 private _totalFeesAccrued;
    uint256 public orderCount;
    mapping(address => bool) public isCIO; // Chief Investment Officer

    event AllocationUpdated(AssetClass indexed class_);
    event ManagerOnboarded(address indexed mgr);
    event RebalanceOrderCreated(uint256 indexed orderId);
    event RebalanceExecuted(uint256 indexed orderId);
    event PerformanceReported(AssetClass indexed class_);

    constructor() Ownable(msg.sender) {
        _totalAUM = FHE.asEuint64(0);
        _totalFeesAccrued = FHE.asEuint64(0);
        FHE.allowThis(_totalAUM);
        FHE.allowThis(_totalFeesAccrued);
        isCIO[msg.sender] = true;
    }

    function addCIO(address cio) external onlyOwner { isCIO[cio] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setAllocation(
        AssetClass class_,
        externalEuint64 encTarget, bytes calldata tProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encBenchmark, bytes calldata bProof
    ) external whenNotPaused {
        require(isCIO[msg.sender], "Not CIO");
        euint64 target = FHE.fromExternal(encTarget, tProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint64 bench = FHE.fromExternal(encBenchmark, bProof);
        AllocationSlice storage slice = allocations[class_];
        // Update total AUM
        _totalAUM = FHE.sub(_totalAUM, FHE.isInitialized(slice.currentValueUSD)
            ? slice.currentValueUSD : FHE.asEuint64(0));
        slice.targetBps = target;
        slice.currentValueUSD = value;
        slice.benchmarkReturn = bench;
        if (!FHE.isInitialized(slice.unrealisedPnL)) {
            slice.unrealisedPnL = FHE.asEuint64(0);
            slice.actualReturn = FHE.asEuint64(0);
            FHE.allowThis(slice.unrealisedPnL);
            FHE.allowThis(slice.actualReturn);
        }
        _totalAUM = FHE.add(_totalAUM, value);
        FHE.allowThis(slice.targetBps);
        FHE.allowThis(slice.currentValueUSD);
        FHE.allowThis(slice.benchmarkReturn);
        FHE.allowThis(_totalAUM);
        emit AllocationUpdated(class_);
    }

    function onboardManager(
        address mgr,
        externalEuint64 encMgmtFee, bytes calldata mProof,
        externalEuint64 encPerfFee, bytes calldata pProof,
        externalEuint64 encAUM, bytes calldata aProof
    ) external onlyOwner {
        euint64 mgmtFee = FHE.fromExternal(encMgmtFee, mProof);
        euint64 perfFee = FHE.fromExternal(encPerfFee, pProof);
        euint64 aum = FHE.fromExternal(encAUM, aProof);
        managers[mgr] = FundManager({
            managementFeeBps: mgmtFee, performanceFeeBps: perfFee,
            aumManaged: aum, cumulativeFeesPaid: FHE.asEuint64(0), active: true
        });
        FHE.allowThis(managers[mgr].managementFeeBps);
        FHE.allowThis(managers[mgr].performanceFeeBps);
        FHE.allowThis(managers[mgr].aumManaged);
        FHE.allowThis(managers[mgr].cumulativeFeesPaid);
        FHE.allow(managers[mgr].managementFeeBps, mgr); // [acl_misconfig]
        FHE.allow(_totalAUM, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFeesAccrued, msg.sender); // [acl_misconfig]
        FHE.allow(managers[mgr].performanceFeeBps, mgr);
        FHE.allow(managers[mgr].aumManaged, mgr);
        emit ManagerOnboarded(mgr);
    }

    function createRebalanceOrder(
        AssetClass from_, AssetClass to_,
        externalEuint64 encAmount, bytes calldata proof
    ) external whenNotPaused returns (uint256 orderId) {
        require(isCIO[msg.sender], "Not CIO");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Verify from allocation has sufficient value
        ebool sufficient = FHE.le(amount, allocations[from_].currentValueUSD);
        euint64 transferAmount = FHE.select(sufficient, amount, allocations[from_].currentValueUSD);
        orderId = orderCount++;
        rebalanceOrders[orderId] = RebalanceOrder({
            fromClass: from_, toClass: to_,
            amountUSD: transferAmount,
            executed: false,
            createdAt: block.timestamp,
            authorizedBy: msg.sender
        });
        FHE.allowThis(rebalanceOrders[orderId].amountUSD);
        emit RebalanceOrderCreated(orderId);
    }

    function executeRebalance(uint256 orderId) external whenNotPaused nonReentrant {
        require(isCIO[msg.sender], "Not CIO");
        RebalanceOrder storage order = rebalanceOrders[orderId];
        require(!order.executed, "Already executed");
        AllocationSlice storage fromSlice = allocations[order.fromClass];
        AllocationSlice storage toSlice = allocations[order.toClass];
        fromSlice.currentValueUSD = FHE.sub(fromSlice.currentValueUSD, order.amountUSD);
        toSlice.currentValueUSD = FHE.add(toSlice.currentValueUSD, order.amountUSD);
        order.executed = true;
        fromSlice.lastRebalanceTime = block.timestamp;
        toSlice.lastRebalanceTime = block.timestamp;
        FHE.allowThis(fromSlice.currentValueUSD);
        FHE.allowThis(toSlice.currentValueUSD);
        emit RebalanceExecuted(orderId);
    }

    function reportPerformance(
        AssetClass class_,
        externalEuint64 encActualReturn, bytes calldata proof,
        externalEuint64 encPnL, bytes calldata pnlProof
    ) external {
        require(isCIO[msg.sender], "Not CIO");
        euint64 actualReturn = FHE.fromExternal(encActualReturn, proof);
        euint64 pnl = FHE.fromExternal(encPnL, pnlProof);
        allocations[class_].actualReturn = actualReturn;
        allocations[class_].unrealisedPnL = pnl;
        FHE.allowThis(allocations[class_].actualReturn);
        FHE.allowThis(allocations[class_].unrealisedPnL);
        emit PerformanceReported(class_);
    }

    function accrueManagerFee(address mgr) external {
        require(isCIO[msg.sender], "Not CIO");
        FundManager storage fm = managers[mgr];
        require(fm.active, "Inactive");
        euint64 annualFee = FHE.div(FHE.mul(fm.aumManaged, fm.managementFeeBps), 10000);
        euint64 quarterlyFee = FHE.div(annualFee, 4);
        fm.cumulativeFeesPaid = FHE.add(fm.cumulativeFeesPaid, quarterlyFee);
        _totalFeesAccrued = FHE.add(_totalFeesAccrued, quarterlyFee);
        FHE.allowThis(fm.cumulativeFeesPaid);
        FHE.allow(fm.cumulativeFeesPaid, mgr);
        FHE.allowThis(_totalFeesAccrued);
    }

    function allowBoardView(address boardMember) external onlyOwner {
        FHE.allow(_totalAUM, boardMember);
        FHE.allow(_totalFeesAccrued, boardMember);
        for (uint8 i = 0; i < 6; i++) {
            AssetClass c = AssetClass(i);
            FHE.allow(allocations[c].currentValueUSD, boardMember);
            FHE.allow(allocations[c].actualReturn, boardMember);
            FHE.allow(allocations[c].unrealisedPnL, boardMember);
        }
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