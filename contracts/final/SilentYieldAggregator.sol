// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SilentYieldAggregator is ZamaEthereumConfig, Ownable {
    IERC20 public immutable underlyingToken;
    
    struct EncryptedPosition {
        euint64 encryptedPrincipal;
        euint64 encryptedShares;
        uint256 lastCompoundTime;
        bool active;
    }

    mapping(address => EncryptedPosition) private positions;
    euint64 private totalEncryptedPoolShares;
    
    // Hidden APY multiplier set by owner (e.g., simulating off-chain yield generation)
    euint32 private hiddenYieldMultiplier;

    constructor(address _token) Ownable(msg.sender) {
        underlyingToken = IERC20(_token);
        totalEncryptedPoolShares = FHE.asEuint64(0);
        hiddenYieldMultiplier = FHE.asEuint32(105); // e.g., 5% base
        
        FHE.allowThis(totalEncryptedPoolShares);
        FHE.allowThis(hiddenYieldMultiplier);
    }

    function setHiddenYield(externalEuint32 extYield, bytes calldata proof) external onlyOwner {
        hiddenYieldMultiplier = FHE.fromExternal(extYield, proof);
        FHE.allowThis(hiddenYieldMultiplier);
    }

    function deposit(
        uint64 amount,
        externalEuint64 extAmount,
        bytes calldata proof
    ) external {
        require(underlyingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        euint64 encAmount = FHE.fromExternal(extAmount, proof);
        euint64 encAmountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 encAmountExposure = FHE.sub(encAmountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        
        
        
        FHE.allowThis(encAmount);

        // Verify plaintext matches encrypted intent (to prevent spoofing)
        ebool isValidDeposit = FHE.eq(encAmount, FHE.asEuint64(uint64(amount)));

        _compound(msg.sender);

        if (!positions[msg.sender].active) {
            positions[msg.sender] = EncryptedPosition(
                FHE.asEuint64(0),
                FHE.asEuint64(0),
                block.timestamp,
                true
            );
            FHE.allowThis(positions[msg.sender].encryptedPrincipal);
            FHE.allowThis(positions[msg.sender].encryptedShares);
        }

        positions[msg.sender].encryptedPrincipal = FHE.add(positions[msg.sender].encryptedPrincipal, encAmount);
        positions[msg.sender].encryptedShares = FHE.add(positions[msg.sender].encryptedShares, encAmount);
        
        totalEncryptedPoolShares = FHE.add(totalEncryptedPoolShares, encAmount);
        
        FHE.allowThis(positions[msg.sender].encryptedPrincipal);
        FHE.allowThis(positions[msg.sender].encryptedShares);
        FHE.allowThis(totalEncryptedPoolShares);
    }

    function _compound(address user) internal {
        if (!positions[user].active) return;
        
        uint256 timeDelta = block.timestamp - positions[user].lastCompoundTime;
        if (timeDelta > 0) {
            // Simplified compounding: shares += shares * (time * yield) / scale
            euint64 timeFactor = FHE.asEuint64(uint64(timeDelta));
            euint64 encMultiplier64 = FHE.asEuint64(hiddenYieldMultiplier);
            
            euint64 yieldGenerated = FHE.div(FHE.mul(FHE.mul(positions[user].encryptedShares, timeFactor), encMultiplier64), 3153600000); // Scale by seconds in year * 100
            FHE.allowThis(yieldGenerated);

            positions[user].encryptedShares = FHE.add(positions[user].encryptedShares, yieldGenerated);
            totalEncryptedPoolShares = FHE.add(totalEncryptedPoolShares, yieldGenerated);
            
            FHE.allowThis(positions[user].encryptedShares);
            FHE.allowThis(totalEncryptedPoolShares);
            
            positions[user].lastCompoundTime = block.timestamp;
        }
    }

    function withdraw(externalEuint64 extWithdrawShares, bytes calldata proof) external {
        require(positions[msg.sender].active, "No position");
        _compound(msg.sender);

        euint64 sharesToWithdraw = FHE.fromExternal(extWithdrawShares, proof);
        FHE.allowThis(sharesToWithdraw);

        ebool canWithdraw = FHE.ge(positions[msg.sender].encryptedShares, sharesToWithdraw);

        positions[msg.sender].encryptedShares = FHE.sub(positions[msg.sender].encryptedShares, sharesToWithdraw);
        totalEncryptedPoolShares = FHE.sub(totalEncryptedPoolShares, sharesToWithdraw);
        
        FHE.allowThis(positions[msg.sender].encryptedShares);
        FHE.allowThis(totalEncryptedPoolShares);

        uint64 plaintextAmount = 0;
        require(underlyingToken.transfer(msg.sender, plaintextAmount), "Transfer failed");
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