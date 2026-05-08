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

    function setHiddenArbRatio(externalEuint64 memory extRatio, bytes calldata proof) external {
        require(msg.sender == owner, "Not owner");
        encryptedTargetRatio = FHE.fromExternal(extRatio, proof);
        FHE.allowThis(encryptedTargetRatio);
    }

    function checkAndExecuteArb() external {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        require(reserve0 > 0, "No liquidity");

        // Scale ratio by 1000
        uint64 publicRatio = uint64((uint256(reserve1) * 1000) / uint256(reserve0));
        euint64 encPublicRatio = FHE.asEuint64(publicRatio);
        FHE.allowThis(encPublicRatio);

        // Execute only if public ratio > encrypted target
        ebool arbCondition = FHE.gt(encPublicRatio, encryptedTargetRatio);
        FHE.req(arbCondition);

        // Logic to execute actual flash loan / swap goes here
    }
}