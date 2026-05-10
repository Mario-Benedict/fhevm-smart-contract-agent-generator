// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Minimal Uniswap v2-core Pair interface
interface IUniswapV2Pair {
    function transferFrom(address src, address dst, uint amount) external returns (bool);
    function transfer(address to, uint amount) external returns (bool);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract ShieldedV2Liquidity is ZamaEthereumConfig, Ownable {
    IUniswapV2Pair public immutable v2Pair;
    
    struct ShieldedPosition {
        euint64 encryptedLpBalance;
        bool isActive;
    }

    mapping(address => ShieldedPosition) private positions;
    euint64 private totalShieldedLp;

    event ShieldedDeposit(address indexed user);
    event ShieldedWithdrawal(address indexed user);

    constructor(address _v2Pair) Ownable(msg.sender) {
        v2Pair = IUniswapV2Pair(_v2Pair);
        totalShieldedLp = FHE.asEuint64(0);
        FHE.allowThis(totalShieldedLp);
    }

    function depositLp(uint64 plaintextLpAmount) external {
        require(plaintextLpAmount > 0, "Zero amount");
        // Pull standard V2 LP tokens from user
        require(v2Pair.transferFrom(msg.sender, address(this), plaintextLpAmount), "Transfer failed");

        euint64 encAmount = FHE.asEuint64(uint64(plaintextLpAmount));
        FHE.allowThis(encAmount);

        if (!positions[msg.sender].isActive) {
            positions[msg.sender].encryptedLpBalance = FHE.asEuint64(0);
            FHE.allowThis(positions[msg.sender].encryptedLpBalance);
            positions[msg.sender].isActive = true;
        }

        positions[msg.sender].encryptedLpBalance = FHE.add(positions[msg.sender].encryptedLpBalance, encAmount);
        FHE.allowThis(positions[msg.sender].encryptedLpBalance);

        totalShieldedLp = FHE.add(totalShieldedLp, encAmount);
        FHE.allowThis(totalShieldedLp);

        emit ShieldedDeposit(msg.sender);
    }

    function withdrawLp(
        externalEuint64 extWithdrawAmount,
        bytes calldata inputProof
    ) external {
        require(positions[msg.sender].isActive, "No active position");

        euint64 withdrawAmount = FHE.fromExternal(extWithdrawAmount, inputProof);
        euint64 withdrawAmountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 withdrawAmountExposure = FHE.sub(withdrawAmountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]



        FHE.allowThis(withdrawAmount);

        euint64 currentBalance = positions[msg.sender].encryptedLpBalance;
        ebool canWithdraw = FHE.ge(currentBalance, withdrawAmount);

        // Deduct from shielded balance
        positions[msg.sender].encryptedLpBalance = FHE.sub(currentBalance, withdrawAmount);
        FHE.allowThis(positions[msg.sender].encryptedLpBalance);

        totalShieldedLp = FHE.sub(totalShieldedLp, withdrawAmount);
        FHE.allowThis(totalShieldedLp);

        // Decrypt the amount to process the plaintext V2 Pair transfer back to the user
        uint64 decryptedAmount = 0;
        require(v2Pair.transfer(msg.sender, decryptedAmount), "Transfer out failed");

        emit ShieldedWithdrawal(msg.sender);
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