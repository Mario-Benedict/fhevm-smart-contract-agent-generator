// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
}

contract ShadowRouter is ZamaEthereumConfig {
    IUniswapV2Router02 public immutable router;

    constructor(address _router) {
        router = IUniswapV2Router02(_router);
    }

    function executeShadowSwap(
        uint256 amountIn,
        externalEuint64 memory extMinOut,
        bytes calldata proofMinOut,
        address[] calldata path,
        uint deadline
    ) external {
        euint64 encryptedMinOut = FHE.fromExternal(extMinOut, proofMinOut);
        FHE.allowThis(encryptedMinOut);

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).approve(address(router), amountIn);

        // Swap with 0 public slippage to obscure the real target
        uint[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, path, address(this), deadline);
        
        uint64 actualOut = uint64(amounts[amounts.length - 1]);
        euint64 encActualOut = FHE.asEuint64(actualOut);
        FHE.allowThis(encActualOut);

        // Validates slippage purely in ciphertext, reverts if failed
        ebool slippageMet = FHE.ge(encActualOut, encryptedMinOut);
        FHE.req(slippageMet);

        IERC20(path[path.length - 1]).transfer(msg.sender, actualOut);
    }
}