// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
}

contract DarkOracleArb is ZamaEthereumConfig, AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    IUniswapV2Pair public immutable v2Pair;

    euint64 private encryptedMinPriceRatio;

    event ArbitrageAttempted(address indexed executor);
    event ArbitrageSuccessful();

    constructor(address _v2Pair) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        v2Pair = IUniswapV2Pair(_v2Pair);

        encryptedMinPriceRatio = FHE.asEuint64(0);
        FHE.allowThis(encryptedMinPriceRatio);
    }

    // Oracle feeds a hidden ratio limit
    function updateEncryptedRatio(
        externalEuint64 memory extRatio,
        bytes calldata proof
    ) external onlyRole(ORACLE_ROLE) {
        encryptedMinPriceRatio = FHE.fromExternal(extRatio, proof);
        FHE.allowThis(encryptedMinPriceRatio);
    }

    // Executor attempts to trigger the arb
    function executeDarkArb() external {
        (uint112 reserve0, uint112 reserve1, ) = v2Pair.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Empty reserves");

        // Calculate public ratio scaled by 1000 for precision
        uint64 publicRatio = uint64((uint256(reserve1) * 1000) / uint256(reserve0));
        euint64 encPublicRatio = FHE.asEuint64(publicRatio);
        FHE.allowThis(encPublicRatio);

        // Check if public ratio has deviated enough from the encrypted oracle ratio
        ebool isArbOpportunity = FHE.gt(encPublicRatio, encryptedMinPriceRatio);
        
        // Revert silently if no arb exists to prevent gas waste and reveal
        FHE.req(isArbOpportunity);

        // Execute plaintext swap logic here (Simplified for example)
        v2Pair.swap(0, 1000, address(this), new bytes(0));

        emit ArbitrageSuccessful();
    }
}