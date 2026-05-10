// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PrivateDigitalAssetInheritance is ZamaEthereumConfig, Ownable {
    mapping(address => euint64) public assetVaults;
    mapping(address => address) public designatedHeirs;
    mapping(address => uint256) public lastPing;

    uint256 public timeoutInterval = 365 days;

    constructor() Ownable(msg.sender) {}

    function fundVault(externalEuint64 amountStr, bytes calldata proof, address heir) public {
        assetVaults[msg.sender] = FHE.add(assetVaults[msg.sender], FHE.fromExternal(amountStr, proof));
        designatedHeirs[msg.sender] = heir;
        lastPing[msg.sender] = block.timestamp;
        
        FHE.allowThis(assetVaults[msg.sender]);
    }

    function checkIn() public {
        lastPing[msg.sender] = block.timestamp;
    }

    function claimInheritance(address deceased) public {
        require(msg.sender == designatedHeirs[deceased], "Not heir");
        require(block.timestamp > lastPing[deceased] + timeoutInterval, "Not timed out");

        euint64 amount = assetVaults[deceased];
        assetVaults[msg.sender] = FHE.add(assetVaults[msg.sender], amount);
        assetVaults[deceased] = FHE.asEuint64(0);
        
        FHE.allowThis(assetVaults[msg.sender]);
        FHE.allowThis(assetVaults[deceased]);
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