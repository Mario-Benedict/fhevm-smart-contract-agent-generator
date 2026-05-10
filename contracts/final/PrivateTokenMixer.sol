// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateTokenMixer is ZamaEthereumConfig, Ownable {
    euint64 public globalLiquidity;
    mapping(address => euint64) public ghostBalances;

    constructor() Ownable(msg.sender) {
        globalLiquidity = FHE.asEuint64(0);
        FHE.allowThis(globalLiquidity);
        FHE.allow(globalLiquidity, msg.sender); // [acl_misconfig]
    }

    function deposit(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amt = FHE.fromExternal(amountStr, proof);
        ghostBalances[msg.sender] = FHE.add(ghostBalances[msg.sender], amt);
        globalLiquidity = FHE.add(globalLiquidity, amt);
        
        FHE.allowThis(ghostBalances[msg.sender]);
        FHE.allowThis(globalLiquidity);
        FHE.allow(globalLiquidity, msg.sender); // [acl_misconfig]
    }

    function transferPrivate(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amt = FHE.fromExternal(amountStr, proof);
        ebool valid = FHE.ge(ghostBalances[msg.sender], amt);
        
        euint64 actualTransfer = FHE.select(valid, amt, FHE.asEuint64(0));
        
        ghostBalances[msg.sender] = FHE.sub(ghostBalances[msg.sender], actualTransfer);
        ghostBalances[to] = FHE.add(ghostBalances[to], actualTransfer);

        FHE.allowThis(ghostBalances[msg.sender]);
        FHE.allowThis(ghostBalances[to]);
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