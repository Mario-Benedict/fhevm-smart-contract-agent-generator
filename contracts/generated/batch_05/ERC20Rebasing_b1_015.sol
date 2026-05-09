// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Rebasing_b1_015 - Confidential ERC20 with elastic supply rebase
contract ERC20Rebasing_b1_015 is ZamaEthereumConfig {
    string public name = "Elastic Token";
    string public symbol = "ELAS";
    uint8 public decimals = 9;

    address public owner;
    euint32 private totalSupply;
    mapping(address => euint32) private shares;
    euint32 private totalShares;
    uint256 public rebaseMultiplier; // in basis points (10000 = 1x)

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        rebaseMultiplier = 10000;
        totalSupply = FHE.asEuint32(1_000_000);
        totalShares = FHE.asEuint32(1_000_000);
        shares[msg.sender] = totalShares;
        FHE.allowThis(totalSupply);
        FHE.allowThis(totalShares);
        FHE.allowThis(shares[msg.sender]);
    }

    function rebase(uint256 newMultiplier) public onlyOwner {
        require(newMultiplier > 0, "Invalid multiplier");
        rebaseMultiplier = newMultiplier;
        // Adjust totalSupply
        totalSupply = FHE.mul(totalShares, FHE.asEuint32(uint32(newMultiplier / 10000)));
        FHE.allowThis(totalSupply);
    }

    function transfer(address to, externalEuint32 sharesStr, bytes calldata proof) public {
        euint32 shareAmount = FHE.fromExternal(sharesStr, proof);
        ebool ok = FHE.le(shareAmount, shares[msg.sender]);
        euint32 actual = FHE.select(ok, shareAmount, FHE.asEuint32(0));
        shares[msg.sender] = FHE.sub(shares[msg.sender], actual);
        shares[to] = FHE.add(shares[to], actual);
        FHE.allowThis(shares[msg.sender]);
        FHE.allowThis(shares[to]);
    }

    function allowShares(address viewer) public {
        FHE.allow(shares[msg.sender], viewer);
    }
}
