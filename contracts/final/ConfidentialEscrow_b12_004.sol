// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialEscrow_b12_004 is ZamaEthereumConfig {
    address public arbiter;
    address public buyer;
    address public seller;

    euint64 private depositBalance;
    euint64 private price;

    ebool private isDisputed;
    ebool private isReleased;

    constructor(address _buyer, address _seller) {
        arbiter = msg.sender;
        buyer = _buyer;
        seller = _seller;

        depositBalance = FHE.asEuint64(0);
        price = FHE.asEuint64(0);
        isDisputed = FHE.asEbool(false);
        isReleased = FHE.asEbool(false);

        FHE.allowThis(depositBalance);
        FHE.allowThis(price);
        FHE.allowThis(isDisputed);
        FHE.allowThis(isReleased);
    }

    function setPrice(externalEuint64 priceStr, bytes calldata proof) public {
        require(msg.sender == seller, "Only seller");
        price = FHE.fromExternal(priceStr, proof);
        FHE.allowThis(price);
    }

    function depositFunds(externalEuint64 amountStr, bytes calldata proof) public {
        require(msg.sender == buyer, "Only buyer");
        euint64 deposit = FHE.fromExternal(amountStr, proof);
        depositBalance = FHE.add(depositBalance, deposit);
        FHE.allowThis(depositBalance);
    }

    function releaseFunds() public {
        require(msg.sender == buyer || msg.sender == arbiter, "Not authorized");
        ebool notDisputed = FHE.not(isDisputed);
        ebool isFunded = FHE.ge(depositBalance, price);
        
        ebool canRelease = FHE.and(notDisputed, isFunded);
        isReleased = FHE.select(canRelease, FHE.asEbool(true), isReleased);

        FHE.allowThis(isReleased);
    }

    function dispute() public {
        require(msg.sender == buyer || msg.sender == seller, "Not authorized");
        isDisputed = FHE.asEbool(true);
        FHE.allowThis(isDisputed);
    }
}
