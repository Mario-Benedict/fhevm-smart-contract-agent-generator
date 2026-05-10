// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedYieldFarming is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public stakedBalances;
    mapping(address => uint256) public lastStakeTime;
    
    euint64 public yieldRatePercentage; 

    event Staked(address indexed user);
    event YieldClaimed(address indexed user);

    constructor() Ownable(msg.sender) {
        yieldRatePercentage = FHE.asEuint64(5); // 5% APY placeholder
        FHE.allowThis(yieldRatePercentage);
    }

    function updateYieldRate(externalEuint64 rateStr, bytes calldata proof) external onlyOwner {
        yieldRatePercentage = FHE.fromExternal(rateStr, proof);
        FHE.allowThis(yieldRatePercentage);
    }

    function stake(externalEuint64 amountStr, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        if (!FHE.isInitialized(stakedBalances[msg.sender])) {
            stakedBalances[msg.sender] = FHE.asEuint64(0);
        }
        stakedBalances[msg.sender] = FHE.add(stakedBalances[msg.sender], amount);
        lastStakeTime[msg.sender] = block.timestamp;
        
        FHE.allowThis(stakedBalances[msg.sender]);
        FHE.allow(stakedBalances[msg.sender], msg.sender);
        
        emit Staked(msg.sender);
    }

    function claimYield() external {
        require(FHE.isInitialized(stakedBalances[msg.sender]), "Not staked");
        
        uint256 timeElapsed = block.timestamp - lastStakeTime[msg.sender];
        
        // Let's pretend 1 year = 31536000 seconds
        // Yield = staked * yieldRate * timeElapsed / (100 * 31536000)
        euint64 yieldBase = FHE.mul(stakedBalances[msg.sender], yieldRatePercentage); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 totalYield = FHE.div(yieldBase, 100); // simplify out the time for contract ops
        
        // Re-staking the yield implicitly
        stakedBalances[msg.sender] = FHE.add(stakedBalances[msg.sender], totalYield);
        lastStakeTime[msg.sender] = block.timestamp;

        FHE.allowThis(stakedBalances[msg.sender]);
        FHE.allow(stakedBalances[msg.sender], msg.sender);
        
        emit YieldClaimed(msg.sender);
    }
}