// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WhisperBountyEscrow is ZamaEthereumConfig {
    IERC20 public immutable rewardToken;

    struct BountyPool {
        euint64 encryptedBalance;
        address sponsor;
        bool isActive;
    }

    mapping(bytes32 => BountyPool) public bounties;
    uint256 public bountyCounter;

    constructor(address _rewardToken) {
        rewardToken = IERC20(_rewardToken);
    }

    function fundBounty(uint64 amount) external returns (bytes32) {
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Funding failed");

        euint64 encAmount = FHE.asEuint64(uint64(amount));
        FHE.allowThis(encAmount);

        bytes32 bountyId = keccak256(abi.encodePacked(msg.sender, bountyCounter++));
        
        bounties[bountyId] = BountyPool({
            encryptedBalance: encAmount,
            sponsor: msg.sender,
            isActive: true
        });

        return bountyId;
    }

    function distributeHiddenReward(
        bytes32 bountyId,
        address hunter,
        externalEuint64 extRewardAmount,
        bytes calldata proof
    ) external {
        BountyPool storage pool = bounties[bountyId];
        require(pool.isActive, "Bounty inactive");
        require(msg.sender == pool.sponsor, "Not sponsor");

        euint64 reward = FHE.fromExternal(extRewardAmount, proof);
        FHE.allowThis(reward);

        ebool hasSufficientFunds = FHE.ge(pool.encryptedBalance, reward);

        pool.encryptedBalance = FHE.sub(pool.encryptedBalance, reward);
        FHE.allowThis(pool.encryptedBalance);

        uint64 decryptedReward = 0;
        require(rewardToken.transfer(hunter, decryptedReward), "Reward transfer failed");
    }

    function closeBounty(bytes32 bountyId) external {
        BountyPool storage pool = bounties[bountyId];
        require(msg.sender == pool.sponsor, "Not sponsor");
        require(pool.isActive, "Already closed");

        pool.isActive = false;
        
        uint64 remainingBalance = 0;
        if (remainingBalance > 0) {
            require(rewardToken.transfer(pool.sponsor, remainingBalance), "Refund failed");
        }
    }
}