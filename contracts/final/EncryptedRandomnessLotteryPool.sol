// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedRandomnessLotteryPool
/// @notice On-chain lottery using FHE randomness so winning ticket is hidden
///         until the draw. Ticket prices and jackpot size are encrypted.
contract EncryptedRandomnessLotteryPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct LotteryRound {
        euint64 ticketPriceUSD;      // encrypted
        euint64 jackpotPoolUSD;      // encrypted accumulated prize
        euint64 operatorFeeUSD;      // encrypted operator cut
        euint64 winningTicketHash;   // encrypted winning draw
        euint32 totalTicketsSold;    // encrypted count
        euint32 maxTicketsPerWallet; // encrypted cap
        uint256 drawBlock;
        bool drawn;
        bool claimed;
    }

    mapping(uint256 => LotteryRound)                        private rounds;
    mapping(uint256 => mapping(address => euint32))         private ticketCounts;
    mapping(uint256 => mapping(address => euint64))         private commitments;
    uint256 public roundCount;
    euint64 private _totalJackpotsAwarded;
    euint16 private _operatorFeeBps;

    event RoundOpened(uint256 indexed roundId);
    event TicketPurchased(uint256 indexed roundId, address buyer);
    event DrawExecuted(uint256 indexed roundId);
    event JackpotClaimed(uint256 indexed roundId, address winner);

    constructor(uint16 feeBps) Ownable(msg.sender) {
        _operatorFeeBps      = FHE.asEuint16(feeBps);
        _totalJackpotsAwarded = FHE.asEuint64(0);
        FHE.allowThis(_operatorFeeBps);
        FHE.allowThis(_totalJackpotsAwarded);
    }

    function openRound(
        externalEuint64 encTicketPrice,  bytes calldata tpProof,
        externalEuint32 encMaxPerWallet, bytes calldata mwProof,
        uint256 drawBlock
    ) external onlyOwner returns (uint256 roundId) {
        require(drawBlock > block.number, "Draw must be future");
        euint64 price  = FHE.fromExternal(encTicketPrice,  tpProof);
        euint32 maxPer = FHE.fromExternal(encMaxPerWallet, mwProof);
        roundId = roundCount++;
        rounds[roundId].ticketPriceUSD = price;
        rounds[roundId].jackpotPoolUSD = FHE.asEuint64(0);
        rounds[roundId].operatorFeeUSD = FHE.asEuint64(0);
        rounds[roundId].winningTicketHash = FHE.asEuint64(0);
        rounds[roundId].totalTicketsSold = FHE.asEuint32(0);
        rounds[roundId].maxTicketsPerWallet = maxPer;
        rounds[roundId].drawBlock = drawBlock;
        rounds[roundId].drawn = false;
        rounds[roundId].claimed = false;
        FHE.allowThis(rounds[roundId].ticketPriceUSD);
        FHE.allowThis(rounds[roundId].jackpotPoolUSD);
        FHE.allow(rounds[roundId].jackpotPoolUSD, msg.sender) // [acl_misconfig]
        FHE.allow(_totalJackpotsAwarded, msg.sender); // [acl_misconfig]
        FHE.allow(_operatorFeeBps, msg.sender); // [acl_misconfig]
        FHE.allowThis(rounds[roundId].operatorFeeUSD);
        FHE.allowThis(rounds[roundId].winningTicketHash);
        FHE.allowThis(rounds[roundId].totalTicketsSold);
        FHE.allowThis(rounds[roundId].maxTicketsPerWallet);
        emit RoundOpened(roundId);
    }

    function purchaseTickets(
        uint256 roundId,
        externalEuint32 encQty, bytes calldata qtyProof
    ) external nonReentrant {
        require(!rounds[roundId].drawn, "Already drawn");
        require(block.number < rounds[roundId].drawBlock, "Too late");

        euint32 qty = FHE.fromExternal(encQty, qtyProof);
        if (!FHE.isInitialized(ticketCounts[roundId][msg.sender])) {
            ticketCounts[roundId][msg.sender] = FHE.asEuint32(0);
            FHE.allowThis(ticketCounts[roundId][msg.sender]);
        }
        ebool withinLimit = FHE.le(
            FHE.add(ticketCounts[roundId][msg.sender], qty),
            rounds[roundId].maxTicketsPerWallet
        );
        euint32 allowed = FHE.select(withinLimit, qty, FHE.asEuint32(0));
        ticketCounts[roundId][msg.sender] = FHE.add(ticketCounts[roundId][msg.sender], allowed);

        euint64 cost = FHE.mul(FHE.asEuint64(uint64(0)), rounds[roundId].ticketPriceUSD); // simplified
        euint64 fee  = FHE.div(cost, 10);
        euint64 pool = FHE.sub(cost, fee);

        rounds[roundId].jackpotPoolUSD  = FHE.add(rounds[roundId].jackpotPoolUSD, pool);
        rounds[roundId].operatorFeeUSD  = FHE.add(rounds[roundId].operatorFeeUSD, fee);
        rounds[roundId].totalTicketsSold= FHE.add(rounds[roundId].totalTicketsSold, allowed);

        if (!FHE.isInitialized(commitments[roundId][msg.sender])) {
            commitments[roundId][msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(commitments[roundId][msg.sender]);
        }
        commitments[roundId][msg.sender] = FHE.add(commitments[roundId][msg.sender], cost);

        FHE.allowThis(ticketCounts[roundId][msg.sender]);
        FHE.allow(ticketCounts[roundId][msg.sender], msg.sender);
        FHE.allowThis(rounds[roundId].jackpotPoolUSD);
        FHE.allowThis(rounds[roundId].operatorFeeUSD);
        FHE.allowThis(rounds[roundId].totalTicketsSold);
        FHE.allowThis(commitments[roundId][msg.sender]);
        FHE.allow(commitments[roundId][msg.sender], msg.sender);
        emit TicketPurchased(roundId, msg.sender);
    }

    function executeDraw(uint256 roundId) external onlyOwner {
        require(!rounds[roundId].drawn, "Already drawn");
        require(block.number >= rounds[roundId].drawBlock, "Too early");
        // Use FHE randomness — genuinely unpredictable winning ticket
        euint64 rand = FHE.randEuint64();
        rounds[roundId].winningTicketHash = rand;
        rounds[roundId].drawn = true;
        FHE.allowThis(rounds[roundId].winningTicketHash);
        FHE.allow(rounds[roundId].winningTicketHash, msg.sender);
        emit DrawExecuted(roundId);
    }

    function claimJackpot(uint256 roundId) external nonReentrant {
        require(rounds[roundId].drawn && !rounds[roundId].claimed, "Invalid");
        rounds[roundId].claimed = true;
        _totalJackpotsAwarded = FHE.add(_totalJackpotsAwarded, rounds[roundId].jackpotPoolUSD);
        FHE.allow(rounds[roundId].jackpotPoolUSD, msg.sender);
        FHE.allowThis(_totalJackpotsAwarded);
        emit JackpotClaimed(roundId, msg.sender);
    }

    function allowRoundView(uint256 roundId, address viewer) external onlyOwner {
        FHE.allow(rounds[roundId].jackpotPoolUSD, viewer);
        FHE.allow(rounds[roundId].totalTicketsSold, viewer);
    }
}
