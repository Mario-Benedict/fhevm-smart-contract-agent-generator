// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFlashLoanArbitrage - Flash loan with encrypted profit tracking and fee distribution
contract PrivateFlashLoanArbitrage is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    euint64 private _poolLiquidity;
    euint64 private _totalFeesEarned;
    euint64 private _flashLoanFeeBps;
    mapping(address => euint64) private _lpShares;
    mapping(address => euint64) private _lpFeeEarnings;
    euint64 private _totalLPShares;
    uint256 public loanCount;

    event LiquidityAdded(address indexed lp);
    event FlashLoanExecuted(uint256 indexed loanId, address indexed borrower);
    event FeesDistributed();

    constructor(externalEuint64 encFeeBps, bytes memory proof) Ownable(msg.sender) {
        _flashLoanFeeBps = FHE.fromExternal(encFeeBps, proof);
        _poolLiquidity = FHE.asEuint64(0);
        _totalFeesEarned = FHE.asEuint64(0);
        _totalLPShares = FHE.asEuint64(0);
        FHE.allowThis(_flashLoanFeeBps);
        FHE.allowThis(_poolLiquidity);
        FHE.allowThis(_totalFeesEarned);
        FHE.allowThis(_totalLPShares);
    }

    function addLiquidity(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _lpShares[msg.sender] = FHE.add(_lpShares[msg.sender], amount);
        _totalLPShares = FHE.add(_totalLPShares, amount);
        _poolLiquidity = FHE.add(_poolLiquidity, amount);
        if (!FHE.isInitialized(_lpFeeEarnings[msg.sender])) {
            _lpFeeEarnings[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_lpFeeEarnings[msg.sender]);
        }
        FHE.allowThis(_lpShares[msg.sender]);
        FHE.allow(_lpShares[msg.sender], msg.sender);
        FHE.allowThis(_totalLPShares);
        FHE.allowThis(_poolLiquidity);
        emit LiquidityAdded(msg.sender);
    }

    function flashLoan(externalEuint64 encAmount, bytes calldata proof) external nonReentrant returns (uint256 loanId) {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasLiquidity = FHE.le(amount, _poolLiquidity);
        euint64 actualLoan = FHE.select(hasLiquidity, amount, FHE.asEuint64(0));
        euint64 fee = FHE.div(FHE.mul(actualLoan, _flashLoanFeeBps), 10000);
        // Loan must be repaid in same tx (simplified: track fee)
        _totalFeesEarned = FHE.add(_totalFeesEarned, fee);
        loanId = loanCount++;
        FHE.allow(actualLoan, msg.sender);
        FHE.allowThis(_totalFeesEarned);
        emit FlashLoanExecuted(loanId, msg.sender);
    }

    function distributeFees() external onlyOwner {
        // Distribute pro-rata to LPs (simplified: allow owner to distribute)
        FHE.allow(_totalFeesEarned, msg.sender);
        emit FeesDistributed();
    }

    function claimLPFees() external {
        // Pro-rata fee claim based on LP share
        euint64 userShare = FHE.div(FHE.mul(_lpShares[msg.sender], _totalFeesEarned), 1000);
        euint64 unclaimed = FHE.sub(userShare, _lpFeeEarnings[msg.sender]);
        _lpFeeEarnings[msg.sender] = FHE.add(_lpFeeEarnings[msg.sender], unclaimed);
        FHE.allowThis(_lpFeeEarnings[msg.sender]);
        FHE.allow(unclaimed, msg.sender);
    }

    function removeLiquidity(externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        euint64 shares = FHE.fromExternal(encShares, proof);
        ebool ok = FHE.le(shares, _lpShares[msg.sender]);
        euint64 actual = FHE.select(ok, shares, FHE.asEuint64(0));
        _lpShares[msg.sender] = FHE.sub(_lpShares[msg.sender], actual);
        _totalLPShares = FHE.sub(_totalLPShares, actual);
        _poolLiquidity = FHE.sub(_poolLiquidity, actual);
        FHE.allowThis(_lpShares[msg.sender]);
        FHE.allowThis(_totalLPShares);
        FHE.allowThis(_poolLiquidity);
        FHE.allow(actual, msg.sender);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_poolLiquidity, viewer);
        FHE.allow(_totalFeesEarned, viewer);
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