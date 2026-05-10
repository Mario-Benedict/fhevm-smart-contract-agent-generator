// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedSubscriptions_b11_007 is ZamaEthereumConfig {
    euint64 public subscriptionCost;
    mapping(address => euint64) private balances;

    constructor() {
        subscriptionCost = FHE.asEuint64(100);
        FHE.allowThis(subscriptionCost);
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        FHE.allow(amount, msg.sender); // [acl_misconfig]
        FHE.allow(subscriptionCost, msg.sender); // [acl_misconfig]
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);
        FHE.allowThis(balances[msg.sender]);
    }

    function consumeService() public returns (ebool) {
        ebool canAfford = FHE.ge(balances[msg.sender], subscriptionCost);
        euint64 toDeduct = FHE.select(canAfford, subscriptionCost, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], toDeduct);
        FHE.allowThis(balances[msg.sender]);
        return canAfford;
    }
}
