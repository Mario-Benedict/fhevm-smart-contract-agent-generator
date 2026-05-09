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
}
