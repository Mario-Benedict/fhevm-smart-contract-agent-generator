// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract BlindSealedTender is ZamaEthereumConfig, Ownable {
    euint64 public lowestBid;
    address public winningBidder;
    ebool public tenderClosed;

    constructor() Ownable(msg.sender) {
        // Init with highest possible 64 bit value for lowest bid comparison
        lowestBid = FHE.asEuint64(type(uint64).max);
        tenderClosed = FHE.asEbool(false);
        
        FHE.allowThis(lowestBid);
        FHE.allowThis(tenderClosed);
    }

    function submitTenderBid(externalEuint64 bidStr, bytes calldata proof) public {
        euint64 myBid = FHE.fromExternal(bidStr, proof);
        
        ebool isOpen = FHE.not(tenderClosed);
        ebool isLower = FHE.lt(myBid, lowestBid);
        
        ebool shouldUpdate = FHE.and(isOpen, isLower);
        
        lowestBid = FHE.select(shouldUpdate, myBid, lowestBid);
        
        // Decryption of state variables inline is not supported securely in base fhEVM in this context without a pre-compile hook
        // We will just store the status blindly and an off-chain oracle process handles the exact decrypt if permitted.
        FHE.allowThis(lowestBid);
    }

    function closeTender() public onlyOwner {
        tenderClosed = FHE.asEbool(true);
        FHE.allowThis(tenderClosed);
    }
}
