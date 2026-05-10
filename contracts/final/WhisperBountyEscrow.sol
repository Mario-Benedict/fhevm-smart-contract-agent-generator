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
        FHE.allow(encAmount, msg.sender); // [acl_misconfig]
        FHE.allow(encAmount, msg.sender); // [acl_misconfig]

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

        pool.encryptedBalance = FHE.sub(pool.encryptedBalance, reward); // [arithmetic_overflow_underflow]
        euint64 rewardScaled = FHE.mul(reward, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

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