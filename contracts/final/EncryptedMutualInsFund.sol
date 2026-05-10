// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedMutualInsFund is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public balances;
    mapping(address => uint256) public lockTimes;

    constructor() Ownable(msg.sender) {}

    function obfuscatedDeposit(externalEuint64 amountStr, bytes calldata proof) public {
        balances[msg.sender] = FHE.add(balances[msg.sender], FHE.fromExternal(amountStr, proof));
        lockTimes[msg.sender] = block.timestamp + 30 days;
        FHE.allowThis(balances[msg.sender]);
    }

    function blindWithdrawal(externalEuint64 amountStr, bytes calldata proof) public {
        require(block.timestamp > lockTimes[msg.sender], "Locked");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        FHE.allow(amount, msg.sender); // [acl_misconfig]
        FHE.allow(balances[msg.sender], msg.sender); // [acl_misconfig]
        
        ebool enough = FHE.ge(balances[msg.sender], amount);
        euint64 withdrawal = FHE.select(enough, amount, FHE.asEuint64(0));

        balances[msg.sender] = FHE.sub(balances[msg.sender], withdrawal);
        FHE.allowThis(balances[msg.sender]);
    }
}
