// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WhisperIncentives is ZamaEthereumConfig {
    IERC20 public immutable rewardToken;
    address public admin;

    struct Provider {
        euint32 encryptedMultiplier;
        uint256 plaintextLpAmount;
        uint256 lastClaim;
    }

    mapping(address => Provider) public providers;

    constructor(address _rewardToken) {
        rewardToken = IERC20(_rewardToken);
        admin = msg.sender;
    }

    function setEncryptedMultiplier(address user, externalEuint32 extMulti, bytes calldata proof) external {
        require(msg.sender == admin, "Not admin");
        euint32 multi = FHE.fromExternal(extMulti, proof);
        FHE.allowThis(multi);
        providers[user].encryptedMultiplier = multi;
    }

    function claimWhisperRewards() external {
        Provider storage p = providers[msg.sender];
        require(p.plaintextLpAmount > 0, "No LP");
        require(FHE.isInitialized(p.encryptedMultiplier), "No multiplier");

        uint256 timePassed = block.timestamp - p.lastClaim;
        uint256 baseReward = timePassed * p.plaintextLpAmount; // Simplified base calc

        euint64 encBase = FHE.asEuint64(uint64(baseReward));
        euint64 encMulti = FHE.asEuint64(p.encryptedMultiplier);
        
        euint64 totalReward = FHE.mul(encBase, encMulti);
        FHE.allowThis(totalReward);

        p.lastClaim = block.timestamp;
        
        uint64 decryptReward = 0;
        require(rewardToken.transfer(msg.sender, decryptReward), "Transfer failed");
    }
}