// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ShieldedLiquidityFarm is ZamaEthereumConfig, AccessControl {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    IERC20 public immutable stakingToken; // e.g., Uniswap V2 LP Token
    
    struct Farmer {
        uint256 plaintextStaked;
        euint16 encryptedYieldMultiplier;
        euint64 encryptedUnclaimedRewards;
        uint256 lastUpdate;
    }

    mapping(address => Farmer) private farmers;
    uint256 public constant BASE_YIELD_RATE = 100; // Tokens per second per LP token

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    constructor(address _stakingToken) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        stakingToken = IERC20(_stakingToken);
    }

    // Admin sets a hidden multiplier for a user (e.g., 1x to 5x)
    function setEncryptedMultiplier(
        address user,
        externalEuint16 extMultiplier,
        bytes calldata proof
    ) external onlyRole(MANAGER_ROLE) {
        _updateRewards(user);
        
        euint16 multiplier = FHE.fromExternal(extMultiplier, proof);
        FHE.allowThis(multiplier);
        farmers[user].encryptedYieldMultiplier = multiplier;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Cannot stake 0");
        _updateRewards(msg.sender);

        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Initialize multiplier if brand new
        if (!FHE.isInitialized(farmers[msg.sender].encryptedYieldMultiplier)) {
            farmers[msg.sender].encryptedYieldMultiplier = FHE.asEuint16(1); // Default 1x
            FHE.allowThis(farmers[msg.sender].encryptedYieldMultiplier);
            
            farmers[msg.sender].encryptedUnclaimedRewards = FHE.asEuint64(0);
            FHE.allowThis(farmers[msg.sender].encryptedUnclaimedRewards);
        }

        farmers[msg.sender].plaintextStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function _updateRewards(address user) internal {
        Farmer storage f = farmers[user];
        if (f.plaintextStaked == 0 || !FHE.isInitialized(f.encryptedYieldMultiplier)) {
            f.lastUpdate = block.timestamp;
            return;
        }

        uint256 timeDelta = block.timestamp - f.lastUpdate;
        if (timeDelta > 0) {
            // Base calculation in plaintext: Time * Staked * BaseRate
            uint256 baseReward = timeDelta * f.plaintextStaked * BASE_YIELD_RATE;
            
            // Apply encrypted multiplier
            euint64 encBaseReward = FHE.asEuint64(uint64(baseReward));
            euint64 encMultiplier64 = FHE.asEuint64(f.encryptedYieldMultiplier); // Cast to matching type
            
            euint64 earned = FHE.mul(encBaseReward, encMultiplier64);
            FHE.allowThis(earned);

            f.encryptedUnclaimedRewards = FHE.add(f.encryptedUnclaimedRewards, earned);
            FHE.allowThis(f.encryptedUnclaimedRewards);
        }
        
        f.lastUpdate = block.timestamp;
    }

    function viewEncryptedRewards() external view returns (euint64) {
        return farmers[msg.sender].encryptedUnclaimedRewards;
    }

    function withdraw(uint256 amount) external {
        require(farmers[msg.sender].plaintextStaked >= amount, "Insufficient staked");
        _updateRewards(msg.sender);
        
        farmers[msg.sender].plaintextStaked -= amount;
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
        
        emit Withdrawn(msg.sender, amount);
    }
}