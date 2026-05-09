// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDeFiFlashLoanAudit
/// @notice Encrypted flash loan audit trail: private loan amounts per borrower,
///         hidden fee revenues per protocol, confidential arbitrage profits,
///         and encrypted MEV capture metrics.
contract PrivateDeFiFlashLoanAudit is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct FlashLoanRecord {
        address borrower;
        address tokenBorrowed;
        euint64 amountBorrowed;        // encrypted loan amount
        euint64 feePaid;               // encrypted fee paid
        euint64 arbitrageProfitEst;    // encrypted estimated profit captured
        euint64 gasCostWei;            // encrypted gas spent
        uint256 blockNumber;
        bool successful;
    }

    struct ProtocolFeePool {
        address protocol;
        euint64 totalFeesCollectedUSD; // encrypted total fees
        euint64 totalVolumeUSD;        // encrypted total volume
        euint16 feeRateBps;            // encrypted fee rate
        uint256 lastUpdateBlock;
    }

    mapping(uint256 => FlashLoanRecord) private records;
    mapping(uint256 => ProtocolFeePool) private protocols;
    mapping(address => uint256) private protocolIndex;
    mapping(address => bool) public isAuditAgent;

    uint256 public recordCount;
    uint256 public protocolCount;
    euint64 private _totalFlashLoanVolumeUSD;
    euint64 private _totalFeesGlobalUSD;
    euint64 private _totalArbitrageProfitsUSD;

    event FlashLoanRecorded(uint256 indexed id, address borrower);
    event ProtocolRegistered(uint256 indexed id, address protocol);

    modifier onlyAuditAgent() {
        require(isAuditAgent[msg.sender] || msg.sender == owner(), "Not audit agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFlashLoanVolumeUSD = FHE.asEuint64(0);
        _totalFeesGlobalUSD = FHE.asEuint64(0);
        _totalArbitrageProfitsUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalFlashLoanVolumeUSD);
        FHE.allowThis(_totalFeesGlobalUSD);
        FHE.allowThis(_totalArbitrageProfitsUSD);
        isAuditAgent[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAuditAgent(address a) external onlyOwner { isAuditAgent[a] = true; }

    function registerProtocol(
        address protocol,
        externalEuint16 encFeeRate, bytes calldata frProof
    ) external onlyOwner returns (uint256 id) {
        euint16 feeRate = FHE.fromExternal(encFeeRate, frProof);
        id = protocolCount++;
        protocolIndex[protocol] = id;
        protocols[id] = ProtocolFeePool({
            protocol: protocol, totalFeesCollectedUSD: FHE.asEuint64(0),
            totalVolumeUSD: FHE.asEuint64(0), feeRateBps: feeRate,
            lastUpdateBlock: block.number
        });
        FHE.allowThis(protocols[id].totalFeesCollectedUSD); FHE.allow(protocols[id].totalFeesCollectedUSD, protocol);
        FHE.allowThis(protocols[id].totalVolumeUSD); FHE.allow(protocols[id].totalVolumeUSD, protocol);
        FHE.allowThis(protocols[id].feeRateBps);
        emit ProtocolRegistered(id, protocol);
    }

    function recordFlashLoan(
        address borrower, address tokenBorrowed,
        externalEuint64 encAmount, bytes calldata amProof,
        externalEuint64 encFee, bytes calldata feeProof,
        externalEuint64 encArbitrageProfit, bytes calldata arbProof,
        externalEuint64 encGasCost, bytes calldata gasProof,
        bool successful
    ) external onlyAuditAgent whenNotPaused returns (uint256 id) {
        euint64 amount = FHE.fromExternal(encAmount, amProof);
        euint64 fee    = FHE.fromExternal(encFee, feeProof);
        euint64 arb    = FHE.fromExternal(encArbitrageProfit, arbProof);
        euint64 gas_   = FHE.fromExternal(encGasCost, gasProof);
        id = recordCount++;
        records[id] = FlashLoanRecord({
            borrower: borrower, tokenBorrowed: tokenBorrowed, amountBorrowed: amount,
            feePaid: fee, arbitrageProfitEst: arb, gasCostWei: gas_,
            blockNumber: block.number, successful: successful
        });
        _totalFlashLoanVolumeUSD = FHE.add(_totalFlashLoanVolumeUSD, amount);
        _totalFeesGlobalUSD = FHE.add(_totalFeesGlobalUSD, fee);
        _totalArbitrageProfitsUSD = FHE.add(_totalArbitrageProfitsUSD, arb);
        uint256 pid = protocolIndex[msg.sender];
        if (protocols[pid].protocol == msg.sender) {
            protocols[pid].totalVolumeUSD = FHE.add(protocols[pid].totalVolumeUSD, amount);
            protocols[pid].totalFeesCollectedUSD = FHE.add(protocols[pid].totalFeesCollectedUSD, fee);
            FHE.allowThis(protocols[pid].totalVolumeUSD); FHE.allowThis(protocols[pid].totalFeesCollectedUSD);
        }
        FHE.allowThis(records[id].amountBorrowed); FHE.allow(records[id].amountBorrowed, borrower);
        FHE.allowThis(records[id].feePaid); FHE.allow(records[id].feePaid, borrower);
        FHE.allowThis(records[id].arbitrageProfitEst); FHE.allow(records[id].arbitrageProfitEst, borrower);
        FHE.allowThis(records[id].gasCostWei);
        FHE.allowThis(_totalFlashLoanVolumeUSD); FHE.allowThis(_totalFeesGlobalUSD); FHE.allowThis(_totalArbitrageProfitsUSD);
        emit FlashLoanRecorded(id, borrower);
    }

    function allowAuditStats(address viewer) external onlyOwner {
        FHE.allow(_totalFlashLoanVolumeUSD, viewer);
        FHE.allow(_totalFeesGlobalUSD, viewer);
        FHE.allow(_totalArbitrageProfitsUSD, viewer);
    }
}
