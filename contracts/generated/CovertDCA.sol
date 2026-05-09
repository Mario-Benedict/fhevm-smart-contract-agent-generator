// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUniswapV2Router {
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
}

contract CovertDCA is ZamaEthereumConfig {
    IUniswapV2Router public immutable router;
    
    struct DCAPlan {
        euint64 encryptedTotalBudget;
        euint64 encryptedAmountPerPeriod;
        uint256 nextExecutionTime;
        uint256 periodInterval;
        address tokenIn;
        address tokenOut;
        bool isActive;
    }

    mapping(address => DCAPlan) public plans;

    constructor(address _router) {
        router = IUniswapV2Router(_router);
    }

    function createDCAPlan(
        externalEuint64 extTotalBudget,
        externalEuint64 extAmountPerPeriod,
        bytes calldata proofTotal,
        bytes calldata proofPeriod,
        address _tokenIn,
        address _tokenOut,
        uint256 _interval
    ) external {
        euint64 budget = FHE.fromExternal(extTotalBudget, proofTotal);
        euint64 amount = FHE.fromExternal(extAmountPerPeriod, proofPeriod);
        
        FHE.allowThis(budget);
        FHE.allowThis(amount);

        // Pull max potential budget in plaintext to escrow (simplified for example)
        IERC20(_tokenIn).transferFrom(msg.sender, address(this), 0);

        plans[msg.sender] = DCAPlan({
            encryptedTotalBudget: budget,
            encryptedAmountPerPeriod: amount,
            nextExecutionTime: block.timestamp + _interval,
            periodInterval: _interval,
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            isActive: true
        });
    }

    function executeNextPeriod(address user) external {
        DCAPlan storage plan = plans[user];
        require(plan.isActive && block.timestamp >= plan.nextExecutionTime, "Not ready");

        ebool hasBudget = FHE.ge(plan.encryptedTotalBudget, plan.encryptedAmountPerPeriod);

        plan.encryptedTotalBudget = FHE.sub(plan.encryptedTotalBudget, plan.encryptedAmountPerPeriod);
        FHE.allowThis(plan.encryptedTotalBudget);
        plan.nextExecutionTime += plan.periodInterval;

        uint64 executionAmount = 0;
        
        IERC20(plan.tokenIn).approve(address(router), executionAmount);
        address[] memory path = new address[](2);
        path[0] = plan.tokenIn;
        path[1] = plan.tokenOut;

        router.swapExactTokensForTokens(executionAmount, 0, path, user, block.timestamp);
    }
}