// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VeiledSwapEscrow is ZamaEthereumConfig {
    struct Escrow {
        euint64 encryptedTokenAAmount;
        euint64 encryptedMinTokenBAmount;
        address partyA;
        address partyB;
        bool isSettled;
    }

    mapping(uint256 => Escrow) public escrows;
    uint256 public escrowCounter;

    function createVeiledEscrow(
        address partyB,
        externalEuint64 extAmountA,
        externalEuint64 extMinB,
        bytes calldata proofA,
        bytes calldata proofB
    ) external {
        euint64 amountA = FHE.fromExternal(extAmountA, proofA);
        euint64 amountAWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 amountAExposure = FHE.sub(amountAWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 minB = FHE.fromExternal(extMinB, proofB);

        FHE.allowThis(amountA);

        FHE.allow(amountA, msg.sender); // [acl_misconfig]
        FHE.allow(amountA, msg.sender); // [acl_misconfig]

        FHE.allowThis(minB);

        escrows[escrowCounter++] = Escrow({
            encryptedTokenAAmount: amountA,
            encryptedMinTokenBAmount: minB,
            partyA: msg.sender,
            partyB: partyB,
            isSettled: false
        });
    }

    function settleEscrow(uint256 id, externalEuint64 extProvidedB, bytes calldata proofProv) external {
        Escrow storage e = escrows[id];
        require(!e.isSettled, "Settled");
        require(msg.sender == e.partyB, "Not Party B");

        euint64 providedB = FHE.fromExternal(extProvidedB, proofProv);
        FHE.allowThis(providedB);

        // Ensure Party B provided enough to meet Party A's hidden minimum
        ebool conditionMet = FHE.ge(providedB, e.encryptedMinTokenBAmount);

        e.isSettled = true;
        // Physical transfer logic executed post-validation
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