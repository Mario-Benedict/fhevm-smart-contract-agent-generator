// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateDividendDistribution_b13_002 is ZamaEthereumConfig, Ownable {
    euint64 public totalDividendPool;
    mapping(address => euint64) public shares;
    mapping(address => euint64) public pendingDividends;

    constructor() Ownable(msg.sender) {
        totalDividendPool = FHE.asEuint64(0);
        FHE.allowThis(totalDividendPool);
    }

    function fundDividendPool(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        totalDividendPool = FHE.add(totalDividendPool, amount);
        FHE.allowThis(totalDividendPool);
    }

    function setShares(address investor, externalEuint64 shareStr, bytes calldata proof) public onlyOwner {
        shares[investor] = FHE.fromExternal(shareStr, proof);
        FHE.allowThis(shares[investor]);
    }

    function calculateDividend(address investor, externalEuint64 rateStr, bytes calldata proof) public onlyOwner {
        euint64 rate = FHE.fromExternal(rateStr, proof);
        // Simple representation: shares * rate
        euint64 calculated = FHE.mul(shares[investor], rate);
        pendingDividends[investor] = FHE.add(pendingDividends[investor], calculated);
        FHE.allowThis(pendingDividends[investor]);
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