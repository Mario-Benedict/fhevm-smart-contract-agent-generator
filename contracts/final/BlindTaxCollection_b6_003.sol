// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BlindTaxCollection_b6_003 is ZamaEthereumConfig {
    address public taxAuthority;
    euint64 private totalUnclaimedTaxes;
    
    mapping(address => euint64) private businessRevenue;
    mapping(address => ebool) private hasPaidTax;

    uint64 public constant TAX_RATE_PERCENT = 10;

    constructor() {
        taxAuthority = msg.sender;
        totalUnclaimedTaxes = FHE.asEuint64(0);
        FHE.allowThis(totalUnclaimedTaxes);
    }

    function reportRevenue(externalEuint64 revenueStr, bytes calldata proof) public {
        euint64 revenue = FHE.fromExternal(revenueStr, proof);
        businessRevenue[msg.sender] = FHE.add(businessRevenue[msg.sender], revenue);
        FHE.allowThis(businessRevenue[msg.sender]);
    }

    function payTaxes() public {
        // Can only pay once per cycle (simplified)
        ebool alreadyPaid = hasPaidTax[msg.sender];
        
        euint64 currentRevenue = businessRevenue[msg.sender];
        
        // Calculate 10% tax = (revenue * 10) / 100
        ebool _safeMul2 = FHE.le(currentRevenue, FHE.asEuint64(type(uint32).max));
        euint64 scaledRevenue = FHE.mul(currentRevenue, FHE.asEuint64(uint64(TAX_RATE_PERCENT)));
        euint64 taxOwed = FHE.div(scaledRevenue, 100); // 100 is plaintext divisor
        
        euint64 actualPayment = FHE.select(alreadyPaid, FHE.asEuint64(0), taxOwed);

        // Deduct from business revenue mapping, add to authority pool
        ebool _safeSub15 = FHE.ge(currentRevenue, actualPayment);
        businessRevenue[msg.sender] = FHE.select(_safeSub15, FHE.sub(currentRevenue, actualPayment), FHE.asEuint64(0));
        totalUnclaimedTaxes = FHE.add(totalUnclaimedTaxes, actualPayment);

        // Set paid flag
        ebool payingNow = FHE.not(alreadyPaid);
        hasPaidTax[msg.sender] = FHE.select(payingNow, FHE.asEbool(true), alreadyPaid);

        FHE.allowThis(businessRevenue[msg.sender]);
        FHE.allowThis(totalUnclaimedTaxes);
        FHE.allowThis(hasPaidTax[msg.sender]);
    }
}
