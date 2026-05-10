// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialTokenBase is ZamaEthereumConfig {
    string public name = "Confidential Token";
    string public symbol = "CTK";
    uint8 public decimals = 6;
    
    euint32 private totalSupply;
    mapping(address => euint32) private balances;

    constructor() {
        totalSupply = FHE.asEuint32(1000000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function transfer(
        address to,
        externalEuint32 amountStr,
        bytes calldata inputProof
    ) public {
        euint32 amount = FHE.fromExternal(amountStr, inputProof);
        euint32 currentBal = balances[msg.sender];
        
        ebool canTransfer = FHE.le(amount, currentBal);
        euint32 actualTransfer = FHE.select(canTransfer, amount, FHE.asEuint32(0));

        ebool _safeSub74 = FHE.ge(currentBal, actualTransfer);
        balances[msg.sender] = FHE.select(_safeSub74, FHE.sub(currentBal, actualTransfer), FHE.asEuint32(0));
        FHE.allowThis(balances[msg.sender]);

        euint32 toBal = balances[to];
        balances[to] = FHE.add(toBal, actualTransfer);
        FHE.allowThis(balances[to]);
    }

    function getBalance() public view returns (euint32) {
        return balances[msg.sender];
    }
}
