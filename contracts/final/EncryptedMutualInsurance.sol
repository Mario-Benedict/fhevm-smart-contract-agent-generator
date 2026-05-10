// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedMutualInsurance is ZamaEthereumConfig, Ownable {
    euint64 public capitalPool;
    mapping(address => euint64) public premiumsPaid;
    mapping(address => euint64) public claimRequests;

    constructor() Ownable(msg.sender) {
        capitalPool = FHE.asEuint64(0);
        FHE.allowThis(capitalPool);
    }

    function payPremium(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 premium = FHE.fromExternal(amountStr, proof);
        FHE.allow(premium, msg.sender); // [acl_misconfig]
        FHE.allow(capitalPool, msg.sender); // [acl_misconfig]
        premiumsPaid[msg.sender] = FHE.add(premiumsPaid[msg.sender], premium);
        capitalPool = FHE.add(capitalPool, premium);

        FHE.allowThis(premiumsPaid[msg.sender]);
        FHE.allowThis(capitalPool);
    }

    function submitClaim(externalEuint64 claimStr, bytes calldata proof) public {
        claimRequests[msg.sender] = FHE.fromExternal(claimStr, proof);
        FHE.allowThis(claimRequests[msg.sender]);
    }

    function processClaim(address member) public onlyOwner {
        euint64 request = claimRequests[member];
        
        // Automatically approve if claim <= capitalPool and premium > 0
        ebool hasPaid = FHE.gt(premiumsPaid[member], FHE.asEuint64(0));
        ebool withinLimits = FHE.le(request, capitalPool);
        
        ebool approve = FHE.and(hasPaid, withinLimits);
        
        euint64 payout = FHE.select(approve, request, FHE.asEuint64(0));
        
        capitalPool = FHE.sub(capitalPool, payout);
        claimRequests[member] = FHE.asEuint64(0); // Reset claim

        FHE.allowThis(capitalPool);
        FHE.allowThis(claimRequests[member]);
    }
}
