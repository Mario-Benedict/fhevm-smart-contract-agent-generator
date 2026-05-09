// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title ERC20Lottery_b1_016 - Confidential ERC20 with lottery ticket purchase
contract ERC20Lottery_b1_016 is ZamaEthereumConfig {
    string public name = "Lottery Token";
    string public symbol = "LOTT";
    uint8 public decimals = 18;

    address public owner;
    euint64 private totalSupply;
    mapping(address => euint64) private balances;

    euint64 private lotteryPool;
    mapping(address => uint256) public ticketCount;
    address[] public participants;
    uint256 public ticketPrice; // in plaintext wei-equivalent units
    bool public lotteryOpen;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        totalSupply = FHE.asEuint64(10_000_000);
        balances[msg.sender] = totalSupply;
        lotteryPool = FHE.asEuint64(0);
        ticketPrice = 100;
        FHE.allowThis(totalSupply);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(lotteryPool);
    }

    function openLottery() public onlyOwner {
        lotteryOpen = true;
        delete participants;
    }

    function buyTicket(uint256 numTickets) public {
        require(lotteryOpen, "Lottery closed");
        require(numTickets > 0 && numTickets <= 10, "1-10 tickets");
        uint64 cost = uint64(ticketPrice * numTickets);
        ebool ok = FHE.ge(balances[msg.sender], FHE.asEuint64(uint64(cost)));
        euint64 payment = FHE.select(ok, FHE.asEuint64(uint64(cost)), FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], payment);
        lotteryPool = FHE.add(lotteryPool, payment);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(lotteryPool);
        if (ticketCount[msg.sender] == 0) {
            participants.push(msg.sender);
        }
        ticketCount[msg.sender] += numTickets;
    }

    function drawWinner() public onlyOwner returns (address winner) {
        require(!lotteryOpen, "Close lottery first");
        require(participants.length > 0, "No participants");
        euint64 rand = FHE.randEuint64();
        FHE.allowThis(rand);
        // Use modulo by participants length for winner index (simplified)
        uint256 winnerIdx = participants.length - 1; // simplified - real impl would decrypt
        winner = participants[winnerIdx];
        balances[winner] = FHE.add(balances[winner], lotteryPool);
        lotteryPool = FHE.asEuint64(0);
        FHE.allowThis(balances[winner]);
        FHE.allowThis(lotteryPool);
    }

    function closeLottery() public onlyOwner {
        lotteryOpen = false;
    }

    function transfer(address to, externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool ok = FHE.le(amount, balances[msg.sender]);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        balances[msg.sender] = FHE.sub(balances[msg.sender], actual);
        balances[to] = FHE.add(balances[to], actual);
        FHE.allowThis(balances[msg.sender]);
        FHE.allowThis(balances[to]);
    }

    function allowBalance(address viewer) public {
        FHE.allow(balances[msg.sender], viewer);
    }
}
