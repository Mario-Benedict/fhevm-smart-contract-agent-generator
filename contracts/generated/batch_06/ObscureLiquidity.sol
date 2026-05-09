// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ObscureLiquidity is ZamaEthereumConfig {
    IERC20 public immutable v2LpToken;
    euint64 private totalEncryptedLp;
    mapping(address => euint64) private encryptedBalances;

    constructor(address _v2LpToken) {
        v2LpToken = IERC20(_v2LpToken);
        totalEncryptedLp = FHE.asEuint64(0);
        FHE.allowThis(totalEncryptedLp);
    }

    function depositObscure(uint64 amount) external {
        require(v2LpToken.transferFrom(msg.sender, address(this), amount), "Deposit failed");
        
        euint64 encAmount = FHE.asEuint64(uint64(amount));
        FHE.allowThis(encAmount);

        if (!FHE.isInitialized(encryptedBalances[msg.sender])) {
            encryptedBalances[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(encryptedBalances[msg.sender]);
        }

        encryptedBalances[msg.sender] = FHE.add(encryptedBalances[msg.sender], encAmount);
        totalEncryptedLp = FHE.add(totalEncryptedLp, encAmount);
        
        FHE.allowThis(encryptedBalances[msg.sender]);
        FHE.allowThis(totalEncryptedLp);
    }

    function withdrawObscure(externalEuint64 extAmount, bytes calldata proof) external {
        euint64 amount = FHE.fromExternal(extAmount, proof);
        FHE.allowThis(amount);

        ebool canWithdraw = FHE.ge(encryptedBalances[msg.sender], amount);

        encryptedBalances[msg.sender] = FHE.sub(encryptedBalances[msg.sender], amount);
        totalEncryptedLp = FHE.sub(totalEncryptedLp, amount);
        
        FHE.allowThis(encryptedBalances[msg.sender]);
        FHE.allowThis(totalEncryptedLp);

        uint64 decryptedAmount = 0;
        require(v2LpToken.transfer(msg.sender, decryptedAmount), "Withdraw failed");
    }
}