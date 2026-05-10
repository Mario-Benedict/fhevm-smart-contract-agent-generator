// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialCreditDelegation is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public creditLines;
    mapping(address => mapping(address => euint64)) public delegatedCredit;

    constructor() Ownable(msg.sender) {}

    function mintCredit(address user, externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        creditLines[user] = FHE.add(creditLines[user], FHE.fromExternal(amountStr, proof));
        FHE.allowThis(creditLines[user]);
    }

    function delegateCredit(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        
        ebool canDelegate = FHE.ge(creditLines[msg.sender], amount);
        euint64 actualDelegate = FHE.select(canDelegate, amount, FHE.asEuint64(0));

        ebool _safeSub23 = FHE.ge(creditLines[msg.sender], actualDelegate);
        creditLines[msg.sender] = FHE.select(_safeSub23, FHE.sub(creditLines[msg.sender], actualDelegate), FHE.asEuint64(0));
        delegatedCredit[msg.sender][to] = FHE.add(delegatedCredit[msg.sender][to], actualDelegate);

        FHE.allowThis(creditLines[msg.sender]);
        FHE.allowThis(delegatedCredit[msg.sender][to]);
    }

    function consumeDelegatedCredit(address from, externalEuint64 amountStr, bytes calldata proof) public returns (ebool) {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool canConsume = FHE.ge(delegatedCredit[from][msg.sender], amount);
        
        euint64 actualConsume = FHE.select(canConsume, amount, FHE.asEuint64(0));
        ebool _safeSub24 = FHE.ge(delegatedCredit[from][msg.sender], actualConsume);
        delegatedCredit[from][msg.sender] = FHE.select(_safeSub24, FHE.sub(delegatedCredit[from][msg.sender], actualConsume), FHE.asEuint64(0));
        
        FHE.allowThis(delegatedCredit[from][msg.sender]);
        return canConsume;
    }
}
