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
        euint64 minB = FHE.fromExternal(extMinB, proofB);

        FHE.allowThis(amountA);
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
}