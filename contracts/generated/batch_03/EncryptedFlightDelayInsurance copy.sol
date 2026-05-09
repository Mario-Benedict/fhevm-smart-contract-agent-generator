// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFlightDelayInsurance - Parametric flight delay insurance with encrypted payouts by delay tier
contract EncryptedFlightDelayInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FlightPolicy {
        address insured;
        string  flightNumber;
        uint256 departureTime;
        euint64 premiumPaid;
        euint64[4] payoutTiers; // [2h, 4h, 8h, cancelled]
        bool    claimed;
        bool    active;
    }

    struct ClaimRecord {
        uint256 policyId;
        euint16 delayMinutes;
        euint64 payoutAmount;
        uint256 claimedAt;
        bool    verified;
    }

    mapping(uint256 => FlightPolicy) public policies;
    mapping(uint256 => ClaimRecord)  public claims;
    mapping(address => uint256[])    public insuredPolicies;
    euint64 private insurancePool;
    uint256 public policyCount;
    uint256 public claimCount;

    event PolicyPurchased(uint256 indexed policyId, address indexed insured, string flightNumber);
    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed policyId);
    event ClaimVerified(uint256 indexed claimId, uint256 delayMinutes);
    event PayoutIssued(uint256 indexed claimId, address indexed insured);

    constructor() Ownable(msg.sender) {
        insurancePool = FHE.asEuint64(0);
        FHE.allowThis(insurancePool);
    }

    function fundPool(externalEuint64 encAmount, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        insurancePool = FHE.add(insurancePool, amount);
        FHE.allowThis(insurancePool);
    }

    function purchasePolicy(
        string  calldata flightNumber,
        uint256 departureTime,
        externalEuint64 encPremium,   bytes calldata premiumProof,
        externalEuint64[4] calldata encPayouts,   bytes[4] calldata payoutProofs
    ) external nonReentrant returns (uint256 policyId) {
        policyId = policyCount++;
        FlightPolicy storage p = policies[policyId];
        p.insured        = msg.sender;
        p.flightNumber   = flightNumber;
        p.departureTime  = departureTime;
        p.premiumPaid    = FHE.fromExternal(encPremium, premiumProof);
        p.active         = true;
        for (uint8 i = 0; i < 4; i++) {
            p.payoutTiers[i] = FHE.fromExternal(encPayouts[i], payoutProofs[i]);
            FHE.allowThis(p.payoutTiers[i]);
        }
        insurancePool = FHE.add(insurancePool, p.premiumPaid);
        FHE.allowThis(p.premiumPaid); FHE.allowThis(insurancePool);
        FHE.allow(p.premiumPaid, msg.sender);
        insuredPolicies[msg.sender].push(policyId);
        emit PolicyPurchased(policyId, msg.sender, flightNumber);
    }

    function submitClaim(
        uint256 policyId,
        externalEuint16 encDelayMins, bytes calldata delayProof
    ) external returns (uint256 claimId) {
        FlightPolicy storage p = policies[policyId];
        require(p.insured == msg.sender, "Not insured");
        require(p.active && !p.claimed, "Invalid policy");
        claimId = claimCount++;
        ClaimRecord storage c = claims[claimId];
        c.policyId     = policyId;
        c.delayMinutes = FHE.fromExternal(encDelayMins, delayProof);
        c.payoutAmount = FHE.asEuint64(0);
        c.claimedAt    = block.timestamp;
        FHE.allowThis(c.delayMinutes); FHE.allowThis(c.payoutAmount);
        FHE.allow(c.delayMinutes, owner());
        emit ClaimSubmitted(claimId, policyId);
    }

    function verifyClaim(uint256 claimId, uint256 actualDelayMinutes) external onlyOwner nonReentrant {
        ClaimRecord storage c = claims[claimId];
        require(!c.verified, "Already verified");
        c.verified = true;
        FlightPolicy storage p = policies[c.policyId];
        p.claimed = true;
        euint64 payout;
        if (actualDelayMinutes >= 480) {
            payout = p.payoutTiers[3];
        } else if (actualDelayMinutes >= 240) {
            payout = p.payoutTiers[2];
        } else if (actualDelayMinutes >= 120) {
            payout = p.payoutTiers[1];
        } else if (actualDelayMinutes >= 60) {
            payout = p.payoutTiers[0];
        } else {
            payout = FHE.asEuint64(0);
        }
        c.payoutAmount = payout;
        FHE.allowThis(c.payoutAmount);
        FHE.allow(c.payoutAmount, p.insured);
        emit ClaimVerified(claimId, actualDelayMinutes);
        if (actualDelayMinutes >= 60) {
            insurancePool = FHE.sub(insurancePool, payout);
            FHE.allowThis(insurancePool);
            FHE.allowTransient(payout, p.insured);
            emit PayoutIssued(claimId, p.insured);
        }
    }
}
