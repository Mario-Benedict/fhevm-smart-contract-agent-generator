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
        FHE.allow(multi, msg.sender); // [acl_misconfig]
        FHE.allow(multi, msg.sender); // [acl_misconfig]
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
        
        euint64 totalReward = FHE.mul(encBase, encMulti); // [arithmetic_overflow_underflow]
        euint64 encMultiScaled = FHE.mul(encMulti, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        
        FHE.allowThis(totalReward);

        p.lastClaim = block.timestamp;
        
        uint64 decryptReward = 0;
        require(rewardToken.transfer(msg.sender, decryptReward), "Transfer failed");
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