// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20MultiSig_b1_013 - Confidential ERC20 requiring multi-sig approval
contract ERC20MultiSig_b1_013 is ZamaEthereumConfig {
    string public name = "MultiSig Token";
    string public symbol = "MSTK";
    uint8 public decimals = 18;

    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    address[3] public signers;
    uint8 public threshold;

    struct PendingTransfer {
        address from;
        address to;
        euint64 amount;
        uint8 approvals;
        mapping(address => bool) approved;
        bool executed;
    }

    mapping(uint256 => PendingTransfer) private pendingTransfers;
    uint256 public nextTransferId;

    constructor(address[3] memory _signers, uint8 _threshold) {
        require(_threshold >= 2 && _threshold <= 3, "Invalid threshold");
        signers = _signers;
        threshold = _threshold;
        totalSupply = FHE.asEuint64(10_000_000);
        balances[msg.sender] = totalSupply;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
    }

    function isSigner(address addr) internal view returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (signers[i] == addr) return true;
        }
        return false;
    }

    function proposeTtransfer(address to, externalEuint64 amountStr, bytes calldata proof) public returns (uint256) {
        require(isSigner(msg.sender), "Not signer");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        uint256 id = nextTransferId++;
        PendingTransfer storage pt = pendingTransfers[id];
        pt.from = msg.sender;
        pt.to = to;
        pt.amount = amount;
        pt.approvals = 1;
        pt.approved[msg.sender] = true;
        FHE.allowThis(pt.amount);
        return id;
    }

    function approve(uint256 id) public {
        require(isSigner(msg.sender), "Not signer");
        PendingTransfer storage pt = pendingTransfers[id];
        require(!pt.executed, "Already executed");
        require(!pt.approved[msg.sender], "Already approved");
        pt.approved[msg.sender] = true;
        pt.approvals++;

        if (pt.approvals >= threshold) {
            pt.executed = true;
            ebool ok = FHE.le(pt.amount, balances[pt.from]);
            euint64 actual = FHE.select(ok, pt.amount, FHE.asEuint64(0));
            balances[pt.from] = FHE.sub(balances[pt.from], actual);
            balances[pt.to] = FHE.add(balances[pt.to], actual);
            FHE.allowThis(balances[pt.from]);
            FHE.allowThis(balances[pt.to]);
        }
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
