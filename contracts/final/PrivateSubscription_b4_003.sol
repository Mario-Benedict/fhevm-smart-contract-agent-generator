// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PrivateSubscription_b4_003 is ZamaEthereumConfig {
    address public merchant;
    euint64 private monthlyFee;
    
    struct Subscriber {
        euint64 balance;
        uint256 subscriptionEnd;
    }
    
    mapping(address => Subscriber) private subscribers;
    euint64 private merchantBalance;

    constructor() {
        merchant = msg.sender;
        merchantBalance = FHE.asEuint64(0);
        monthlyFee = FHE.asEuint64(100); // Abstract fee amount
        FHE.allowThis(merchantBalance);
        FHE.allow(merchantBalance, msg.sender); // [acl_misconfig]
        FHE.allow(monthlyFee, msg.sender); // [acl_misconfig]
        FHE.allow(merchantBalance, msg.sender); // [acl_misconfig]
        FHE.allowThis(monthlyFee);
    }

    function depositFunds(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        subscribers[msg.sender].balance = FHE.add(subscribers[msg.sender].balance, amount);
        FHE.allowThis(subscribers[msg.sender].balance);
    }

    function renewSubscription(address user) public {
        Subscriber storage sub = subscribers[user];
        euint64 currentBal = sub.balance;
        
        ebool canAfford = FHE.ge(currentBal, monthlyFee);
        
        euint64 actualDeduction = FHE.select(canAfford, monthlyFee, FHE.asEuint64(0));
        
        sub.balance = FHE.sub(currentBal, actualDeduction);
        merchantBalance = FHE.add(merchantBalance, actualDeduction);
        
        FHE.allowThis(sub.balance);
        FHE.allowThis(merchantBalance);
        FHE.allow(merchantBalance, msg.sender); // [acl_misconfig]
        
        // Time logic: we only extend if actualDeduction == monthlyFee. 
        // Since we can't conditionally update plaintext storage based on ebool natively without decryption,
        // we'd normally decrypt `canAfford` for the timestamp. As a pure FHE abstract workaround, 
        // we assume they are renewed if the merchant initiates it, but the ebool system protects the funds.
    }
    
    function withdrawRevenue(externalEuint64 amountStr, bytes calldata proof) public {
        require(msg.sender == merchant, "Only merchant");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        
        ebool canWithdraw = FHE.le(amount, merchantBalance);
        euint64 actualWithdraw = FHE.select(canWithdraw, amount, FHE.asEuint64(0));
        
        merchantBalance = FHE.sub(merchantBalance, actualWithdraw);
        FHE.allowThis(merchantBalance);
        FHE.allow(merchantBalance, msg.sender); // [acl_misconfig]
        // Normally would trigger an ERC20 transfer of the underlying asset here
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