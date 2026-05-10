// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedConfidentialEscrow_b7_001 - Encrypted escrow with dispute resolution
contract MixedConfidentialEscrow_b7_001 is ZamaEthereumConfig {
    address public arbiter;

    enum State { Created, Funded, Released, Disputed, Resolved }

    struct Escrow {
        address buyer;
        address seller;
        euint64 amount;
        State state;
        string description;
        uint256 releaseTime;
    }

    mapping(uint256 => Escrow) private escrows;
    uint256 public escrowCount;

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Not arbiter");
        _;
    }

    constructor(address _arbiter) {
        arbiter = _arbiter;
    }

    function createEscrow(
        address seller,
        externalEuint64 amountStr,
        bytes calldata proof,
        string calldata description,
        uint256 timeoutDays
    ) public returns (uint256) {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        euint64 amountWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountExposure = FHE.sub(amountWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        uint256 id = escrowCount++;
        escrows[id] = Escrow({
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            state: State.Funded,
            description: description,
            releaseTime: block.timestamp + timeoutDays * 1 days
        });
        FHE.allowThis(escrows[id].amount);
        FHE.allow(escrows[id].amount, seller);
        return id;
    }

    function release(uint256 escrowId) public {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.buyer, "Not buyer");
        require(e.state == State.Funded, "Invalid state");
        e.state = State.Released;
        FHE.allow(e.amount, e.seller);
    }

    function dispute(uint256 escrowId) public {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.buyer || msg.sender == e.seller, "Not party");
        require(e.state == State.Funded, "Invalid state");
        e.state = State.Disputed;
    }

    function resolve(uint256 escrowId, bool buyerWins) public onlyArbiter {
        Escrow storage e = escrows[escrowId];
        require(e.state == State.Disputed, "Not disputed");
        e.state = State.Resolved;
        if (buyerWins) {
            FHE.allow(e.amount, e.buyer);
        } else {
            FHE.allow(e.amount, e.seller);
        }
    }

    function claimTimeout(uint256 escrowId) public {
        Escrow storage e = escrows[escrowId];
        require(msg.sender == e.seller, "Not seller");
        require(e.state == State.Funded, "Invalid state");
        require(block.timestamp >= e.releaseTime, "Not timed out");
        e.state = State.Released;
        FHE.allow(e.amount, e.seller);
    }

    function allowAmount(uint256 escrowId, address viewer) public onlyArbiter {
        FHE.allow(escrows[escrowId].amount, viewer);
    }
}
