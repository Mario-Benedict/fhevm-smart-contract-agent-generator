// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Minimal Uniswap V2 Router Interface
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract ShadowSwapRelayer is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    IUniswapV2Router02 public immutable uniswapRouter;
    
    struct EncryptedSwapOrder {
        euint64 encryptedAmountIn;
        euint64 encryptedMinAmountOut;
        address tokenIn;
        address tokenOut;
        bool isActive;
    }

    mapping(address => EncryptedSwapOrder) private swapOrders;
    mapping(address => mapping(address => euint64)) private shieldedBalances;

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event OrderPlaced(address indexed user, address tokenIn, address tokenOut);
    event SwapExecuted(address indexed user, address tokenIn, address tokenOut);

    constructor(address _router) Ownable(msg.sender) {
        uniswapRouter = IUniswapV2Router02(_router);
    }

    // User deposits plaintext tokens to get a shielded balance
    function depositPlaintext(address token, uint64 amount) external nonReentrant {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        euint64 encAmount = FHE.asEuint64(amount);
        FHE.allowThis(encAmount);

        if (!FHE.isInitialized(shieldedBalances[msg.sender][token])) {
            shieldedBalances[msg.sender][token] = FHE.asEuint64(0);
            FHE.allowThis(shieldedBalances[msg.sender][token]);
        }

        shieldedBalances[msg.sender][token] = FHE.add(shieldedBalances[msg.sender][token], encAmount);
        FHE.allowThis(shieldedBalances[msg.sender][token]);
        
        emit Deposit(msg.sender, token, amount);
    }

    // User sets up a blind swap parameters
    function placeEncryptedSwap(
        address tokenIn,
        address tokenOut,
        externalEuint64 memory extAmountIn,
        externalEuint64 memory extMinAmountOut,
        bytes calldata proofIn,
        bytes calldata proofMinOut
    ) external {
        euint64 amountIn = FHE.fromExternal(extAmountIn, proofIn);
        euint64 minOut = FHE.fromExternal(extMinAmountOut, proofMinOut);
        
        FHE.allowThis(amountIn);
        FHE.allowThis(minOut);

        // Ensure user has enough shielded balance
        ebool hasBalance = FHE.ge(shieldedBalances[msg.sender][tokenIn], amountIn);
        FHE.req(hasBalance);

        swapOrders[msg.sender] = EncryptedSwapOrder({
            encryptedAmountIn: amountIn,
            encryptedMinAmountOut: minOut,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            isActive: true
        });

        emit OrderPlaced(msg.sender, tokenIn, tokenOut);
    }

    // Keeper executes the trade. Converts to plaintext JUST for the Uniswap routing.
    function executeShadowSwap(address user, uint256 deadline) external nonReentrant {
        EncryptedSwapOrder storage order = swapOrders[user];
        require(order.isActive, "No active order");

        // We must decrypt the exact amount to swap on Uniswap's public AMM
        uint64 amountInPlain = FHE.decrypt(order.encryptedAmountIn);
        
        // Approve router
        IERC20(order.tokenIn).approve(address(uniswapRouter), amountInPlain);

        address[] memory path = new address[](2);
        path[0] = order.tokenIn;
        path[1] = order.tokenOut;

        // Execute swap with 0 minOut temporarily, we check slippage confidentially after
        uint[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountInPlain,
            0, 
            path,
            address(this),
            deadline
        );

        uint64 actualAmountOut = uint64(amounts[1]);
        euint64 encActualOut = FHE.asEuint64(actualAmountOut);
        FHE.allowThis(encActualOut);

        // CONFIDENTIAL SLIPPAGE CHECK
        // If the actual output is less than the encrypted minimum, the transaction reverts
        ebool slippageMet = FHE.ge(encActualOut, order.encryptedMinAmountOut);
        FHE.req(slippageMet);

        // Deduct from tokenIn balance, add to tokenOut balance
        shieldedBalances[user][order.tokenIn] = FHE.sub(shieldedBalances[user][order.tokenIn], order.encryptedAmountIn);
        FHE.allowThis(shieldedBalances[user][order.tokenIn]);

        if (!FHE.isInitialized(shieldedBalances[user][order.tokenOut])) {
            shieldedBalances[user][order.tokenOut] = FHE.asEuint64(0);
            FHE.allowThis(shieldedBalances[user][order.tokenOut]);
        }

        shieldedBalances[user][order.tokenOut] = FHE.add(shieldedBalances[user][order.tokenOut], encActualOut);
        FHE.allowThis(shieldedBalances[user][order.tokenOut]);

        order.isActive = false;
        emit SwapExecuted(user, order.tokenIn, order.tokenOut);
    }
}