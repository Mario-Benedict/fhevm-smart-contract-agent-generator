// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialVentureFund is ZamaEthereumConfig, Ownable {
    euint64 public hurdleRate;
    mapping(address => euint64) public lpCommitments;
    mapping(address => euint64) public lpDistributions;

    constructor() Ownable(msg.sender) {
        hurdleRate = FHE.asEuint64(10); // Example target scalar
        FHE.allowThis(hurdleRate);
    }

    function commitCapital(address lp, externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        lpCommitments[lp] = FHE.add(lpCommitments[lp], FHE.fromExternal(amountStr, proof));
        FHE.allowThis(lpCommitments[lp]);
    }

    function recordReturns(address lp, externalEuint64 grossReturnStr, bytes calldata proof) public onlyOwner {
        euint64 gross = FHE.fromExternal(grossReturnStr, proof);
        
        // Evaluate if returns exceed hurdle criteria mathematically blindly
        ebool _safeMul18 = FHE.le(lpCommitments[lp], FHE.asEuint64(type(uint32).max));
        ebool beatsHurdle = FHE.ge(gross, FHE.mul(lpCommitments[lp], hurdleRate));
        
        euint64 performanceFee = FHE.select(beatsHurdle, FHE.div(gross, 5), FHE.asEuint64(0)); // 20% perf fee represented by div(5)
        ebool _safeSub77 = FHE.ge(gross, performanceFee);
        euint64 netDistribution = FHE.select(_safeSub77, FHE.sub(gross, performanceFee), FHE.asEuint64(0));
        
        lpDistributions[lp] = FHE.add(lpDistributions[lp], netDistribution);
        FHE.allowThis(lpDistributions[lp]);
    }
}
