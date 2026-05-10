// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ShieldedSubscriptionManager is ZamaEthereumConfig {
    IERC20 public immutable paymentToken;

    struct Subscription {
        euint64 encryptedMonthlyAllowance;
        euint64 encryptedTotalBilled;
        uint256 lastBillingPeriod;
        bool isActive;
    }

    mapping(address => mapping(address => Subscription)) private subscriptions; // provider => subscriber => Sub

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
    }

    function authorizeSubscription(
        address provider,
        externalEuint64 extAllowance,
        bytes calldata proof
    ) external {
        euint64 allowance = FHE.fromExternal(extAllowance, proof);
        euint64 allowanceWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 allowanceExposure = FHE.sub(allowanceWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 billed = FHE.asEuint64(0);
        
        FHE.allowThis(allowance);
        FHE.allowThis(billed);

        subscriptions[provider][msg.sender] = Subscription({
            encryptedMonthlyAllowance: allowance,
            encryptedTotalBilled: billed,
            lastBillingPeriod: block.timestamp,
            isActive: true
        });
    }

    function chargeSubscriber(
        address subscriber,
        externalEuint64 extChargeAmount,
        bytes calldata proof
    ) external {
        Subscription storage sub = subscriptions[msg.sender][subscriber];
        require(sub.isActive, "No active subscription");

        // Simple 30 day epoch restriction
        require(block.timestamp >= sub.lastBillingPeriod + 30 days, "Billing period not reached");

        euint64 charge = FHE.fromExternal(extChargeAmount, proof);
        FHE.allowThis(charge);

        ebool withinAllowance = FHE.le(charge, sub.encryptedMonthlyAllowance);

        sub.encryptedTotalBilled = FHE.add(sub.encryptedTotalBilled, charge);
        sub.lastBillingPeriod = block.timestamp;
        FHE.allowThis(sub.encryptedTotalBilled);

        uint64 decryptedCharge = 0;
        require(paymentToken.transferFrom(subscriber, msg.sender, decryptedCharge), "Payment failed");
    }

    function cancelSubscription(address provider) external {
        subscriptions[provider][msg.sender].isActive = false;
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}