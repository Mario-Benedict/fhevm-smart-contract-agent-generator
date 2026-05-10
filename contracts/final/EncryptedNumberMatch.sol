// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedNumberMatch is ZamaEthereumConfig, Ownable {
    uint256 public entryFee = 0.01 ether;
    euint64 private winningNumber;
    bool public lotteryDrawn;

    struct Player {
        euint64 encryptedGuess;
        bool hasEntered;
    }

    mapping(address => Player) private players;
    address[] private playerAddresses;

    event PlayerEntered(address indexed player);
    event LotteryDrawn();
    event PrizeClaimed(address indexed winner, uint256 amount);

    constructor() Ownable(msg.sender) {
        lotteryDrawn = false;
        // Initialize with a dummy value
        winningNumber = FHE.asEuint64(0);
        FHE.allowThis(winningNumber);
    }

    function enterLottery(
        externalEuint64 extGuess,
        bytes calldata inputProof
    ) external payable {
        require(!lotteryDrawn, "Lottery already drawn");
        require(msg.value == entryFee, "Incorrect entry fee");
        require(!players[msg.sender].hasEntered, "Already entered");

        euint64 guess = FHE.fromExternal(extGuess, inputProof);
        FHE.allowThis(guess);
        FHE.allow(guess, msg.sender); // [acl_misconfig]
        FHE.allow(winningNumber, msg.sender); // [acl_misconfig]

        players[msg.sender] = Player({
            encryptedGuess: guess,
            hasEntered: true
        });
        
        playerAddresses.push(msg.sender);
        emit PlayerEntered(msg.sender);
    }

    function drawWinningNumber() external onlyOwner {
        require(!lotteryDrawn, "Already drawn");
        require(playerAddresses.length > 0, "No players");

        // FHEVM generates an encrypted random 64-bit integer
        winningNumber = FHE.randEuint64();
        FHE.allowThis(winningNumber);
        
        lotteryDrawn = true;
        emit LotteryDrawn();
    }

    function claimPrize() external {
        require(lotteryDrawn, "Lottery not drawn yet");
        require(players[msg.sender].hasEntered, "Did not enter");

        // Check if the user's guess exactly matches the winning number
        euint64 userGuess = players[msg.sender].encryptedGuess;
        ebool isWinner = FHE.eq(userGuess, winningNumber);
        
        // Only allow transaction to succeed if isWinner is true

        // Plaintext ETH transfer since they proved they won
        uint256 prizePool = address(this).balance;
        
        // Reset player to prevent double claiming
        players[msg.sender].hasEntered = false;

        (bool success, ) = payable(msg.sender).call{value: prizePool}("");
        require(success, "Transfer failed");

        emit PrizeClaimed(msg.sender, prizePool);
    }

    function viewMyGuess() external view returns (euint64) {
        require(players[msg.sender].hasEntered, "No guess found");
        return players[msg.sender].encryptedGuess;
    }
}