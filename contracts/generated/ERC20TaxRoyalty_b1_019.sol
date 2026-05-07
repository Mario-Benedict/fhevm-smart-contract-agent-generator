// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20TaxRoyalty_b1_019 - Confidential ERC20 with royalty tax to creator
contract ERC20TaxRoyalty_b1_019 is ZamaEthereumConfig {
    string public name = "Royalty Token";
    string public symbol = "RLTK";
    uint8 public decimals = 18;

    address public creator;
    uint8 public royaltyBps; // basis points (100 = 1%)
    euint32 private totalSupply;
    mapping(address => euint32) private balances;
    euint32 private royaltyAccumulated;

    modifier onlyCreator() {
        require(msg.sender == creator, "Not creator");
        _;
    }

    constructor(uint8 _royaltyBps) {
        require(_royaltyBps <= 500, "Max 5%");
        creator = msg.sender;
        royaltyBps = _royaltyBps;
        totalSupply = FHE.asEuint32(10_000_000);
        balances[msg.sender] = totalSupply;
        royaltyAccumulated = FHE.asEuint32(0);
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(royaltyAccumulated);
    }

    function transfer(address to, externalEuint32 amountStr, bytes calldata proof) public {
        euint32 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint32 actual = FHE.select(ok, amount, FHE.asEuint32(0));

        // royalty = actual * royaltyBps / 10000
        euint32 royalty = FHE.mul(actual, FHE.asEuint32(uint32(royaltyBps)));
        euint32 net = FHE.sub(actual, royalty);

        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], net);
        royaltyAccumulated = FHE.add(royaltyAccumulated, royalty);

        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
        FHE.allowThis(royaltyAccumulated);
    }

    function claimRoyalties() public onlyCreator {
        balances[creator] = FHE.add(balances[creator], royaltyAccumulated);
        royaltyAccumulated = FHE.asEuint32(0);
        FHE.allowThis(balances[creator]);
        FHE.allowThis(royaltyAccumulated);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
