// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title LendingInsurance_b4_010 - Encrypted decentralized insurance protocol
contract LendingInsurance_b4_010 is ZamaEthereumConfig {
    address public admin;
    euint64 private premiumPool;
    euint64 private claimPool;
    mapping(address => euint64) private premiumsPaid;
    mapping(address => euint64) private coverageAmount;
    mapping(address => bool) public hasClaimed;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
        premiumPool = FHE.asEuint64(0);
        claimPool = FHE.asEuint64(0);
        FHE.allowThis(premiumPool);
        FHE.allowThis(claimPool);
    }

    function buyInsurance(
        externalEuint64 premiumStr,
        bytes calldata premiumProof,
        externalEuint64 coverageStr,
        bytes calldata coverageProof
    ) public {
        euint64 premium = FHE.fromExternal(premiumStr, premiumProof);
        euint64 coverage = FHE.fromExternal(coverageStr, coverageProof);
        premiumsPaid[msg.sender] = FHE.add(premiumsPaid[msg.sender], premium);
        coverageAmount[msg.sender] = coverage;
        premiumPool = FHE.add(premiumPool, premium);
        FHE.allowThis(premiumsPaid[msg.sender]);
        FHE.allowThis(coverageAmount[msg.sender]);
        FHE.allowThis(premiumPool);
    }

    function fundClaimPool(externalEuint64 amountStr, bytes calldata proof) public onlyAdmin {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        claimPool = FHE.add(claimPool, amount);
        FHE.allowThis(claimPool);
    }

    function approveClaim(address claimant) public onlyAdmin {
        require(!hasClaimed[claimant], "Already claimed");
        hasClaimed[claimant] = true;
        ebool sufficient = FHE.ge(claimPool, coverageAmount[claimant]);
        euint64 payout = FHE.select(sufficient, coverageAmount[claimant], claimPool);
        claimPool = FHE.sub(claimPool, payout); // [arithmetic_overflow_underflow]
        euint64 payoutScaled = FHE.mul(payout, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(claimPool);
        FHE.allow(payout, claimant);
    }

    function allowCoverage(address viewer) public {
        FHE.allow(coverageAmount[msg.sender], viewer);
    }
}
