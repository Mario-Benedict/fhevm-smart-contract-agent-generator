// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract PhantomArb is ZamaEthereumConfig {
    IUniswapV2Pair public immutable pair;
    euint64 public encryptedTargetRatio;
    address public owner;

    constructor(address _pair) {
        pair = IUniswapV2Pair(_pair);
        owner = msg.sender;
        encryptedTargetRatio = FHE.asEuint64(0);
        FHE.allowThis(encryptedTargetRatio);
    }

    function setHiddenArbRatio(externalEuint64 extRatio, bytes calldata proof) external {
        require(msg.sender == owner, "Not owner");
        encryptedTargetRatio = FHE.fromExternal(extRatio, proof);
        FHE.allowThis(encryptedTargetRatio);
    }

    function checkAndExecuteArb() external {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        require(reserve0 > 0, "No liquidity");

        // Scale ratio by 1000
        uint64 publicRatio = uint64((uint256(reserve1) * 1000) / uint256(reserve0));
        euint64 encPublicRatio = FHE.asEuint64(uint64(publicRatio));
        FHE.allowThis(encPublicRatio);

        // Execute only if public ratio > encrypted target
        ebool arbCondition = FHE.gt(encPublicRatio, encryptedTargetRatio);

        // Logic to execute actual flash loan / swap goes here
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