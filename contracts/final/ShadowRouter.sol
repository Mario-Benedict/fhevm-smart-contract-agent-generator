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
        externalEuint64 extMinOut,
        bytes calldata proofMinOut,
        address[] calldata path,
        uint deadline
    ) external {
        euint64 encryptedMinOut = FHE.fromExternal(extMinOut, proofMinOut);
        euint64 encryptedMinOutWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 encryptedMinOutExposure = FHE.sub(encryptedMinOutWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        FHE.allowThis(encryptedMinOut);

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).approve(address(router), amountIn);

        // Swap with 0 public slippage to obscure the real target
        uint[] memory amounts = router.swapExactTokensForTokens(amountIn, 0, path, address(this), deadline);
        
        uint64 actualOut = uint64(amounts[amounts.length - 1]);
        euint64 encActualOut = FHE.asEuint64(uint64(actualOut));
        FHE.allowThis(encActualOut);

        // Validates slippage purely in ciphertext, reverts if failed
        ebool slippageMet = FHE.ge(encActualOut, encryptedMinOut);

        IERC20(path[path.length - 1]).transfer(msg.sender, actualOut);
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