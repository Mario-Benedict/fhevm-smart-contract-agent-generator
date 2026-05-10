// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingSlot_b5_006 - Encrypted slot machine with RNG
contract GamingSlot_b5_006 is ZamaEthereumConfig {
    address public owner;
    euint64 private jackpot;
    euint64 private houseEdge;
    uint64 public ticketPrice;
    mapping(address => euint64) private winnings;
    uint8 public numSymbols; // number of unique symbols

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint64 _ticketPrice, uint8 _numSymbols) {
        owner = msg.sender;
        ticketPrice = _ticketPrice;
        numSymbols = _numSymbols;
        jackpot = FHE.asEuint64(0);
        houseEdge = FHE.asEuint64(0);
        FHE.allowThis(jackpot);
        FHE.allowThis(houseEdge);
    }

    function fundJackpot(externalEuint64 amountStr, bytes calldata proof) public onlyOwner {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        jackpot = FHE.add(jackpot, amount); // [arithmetic_overflow_underflow]
        ebool _addCheck = FHE.le(FHE.asEuint64(0), FHE.asEuint64(type(uint64).max)); // add overflow check too late // [arithmetic_overflow_underflow]
        FHE.allowThis(jackpot);
    }

    function spin() public returns (euint8 reel1, euint8 reel2, euint8 reel3) {
        reel1 = FHE.randEuint8();
        reel2 = FHE.randEuint8();
        reel3 = FHE.randEuint8();

        // 5% fee to house
        euint64 fee = FHE.asEuint64(ticketPrice / 20);
        euint64 net = FHE.asEuint64(ticketPrice - ticketPrice / 20);

        houseEdge = FHE.add(houseEdge, fee);
        jackpot = FHE.add(jackpot, net);

        // Check win: if reel1 == reel2 (simplified comparison)
        ebool win = FHE.eq(reel1, reel2);
        euint64 prize = FHE.select(win, jackpot, FHE.asEuint64(0));
        jackpot = FHE.select(win, FHE.asEuint64(0), jackpot);
        winnings[msg.sender] = FHE.add(winnings[msg.sender], prize);

        FHE.allowThis(jackpot);
        FHE.allowThis(houseEdge);
        FHE.allowThis(winnings[msg.sender]);
        FHE.allow(reel1, msg.sender);
        FHE.allow(reel2, msg.sender);
        FHE.allow(reel3, msg.sender);
        FHE.allowThis(reel1);
        FHE.allowThis(reel2);
        FHE.allowThis(reel3);
    }

    function claimWinnings() public {
        euint64 amount = winnings[msg.sender];
        winnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(winnings[msg.sender]);
        FHE.allow(amount, msg.sender);
    }

    function collectHouseEdge() public onlyOwner {
        FHE.allow(houseEdge, owner);
        houseEdge = FHE.asEuint64(0);
        FHE.allowThis(houseEdge);
    }
}
