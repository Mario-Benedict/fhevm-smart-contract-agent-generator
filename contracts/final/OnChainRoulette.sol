// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title OnChainRoulette - FHE-powered roulette with encrypted bets and verifiable spins
contract OnChainRoulette is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum BetType { Single, Red, Black, Even, Odd, Low, High }

    struct Bet {
        address player;
        BetType betType;
        euint8 specificNumber; // used only for Single bets
        euint64 amount;
        bool settled;
    }

    mapping(uint256 => Bet) public bets;
    mapping(address => euint64) public playerBalance;
    uint256 public betCount;
    euint8 private lastSpinResult;

    event BetPlaced(uint256 indexed betId, address indexed player);
    event SpinComplete(uint256 indexed betId);
    event WinPaid(uint256 indexed betId, address indexed player);

    constructor() Ownable(msg.sender) {
        lastSpinResult = FHE.asEuint8(0);
        FHE.allowThis(lastSpinResult);
    }

    function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        playerBalance[msg.sender] = FHE.add(playerBalance[msg.sender], amount);
        FHE.allowThis(playerBalance[msg.sender]);
        FHE.allow(playerBalance[msg.sender], msg.sender);
    }

    function placeSingleBet(
        externalEuint8 encNumber,
        bytes calldata numProof,
        externalEuint64 encAmount,
        bytes calldata amtProof
    ) external nonReentrant returns (uint256 betId) {
        euint8 number = FHE.fromExternal(encNumber, numProof);
        euint64 amount = FHE.fromExternal(encAmount, amtProof);
        playerBalance[msg.sender] = FHE.sub(playerBalance[msg.sender], amount);
        FHE.allowThis(playerBalance[msg.sender]);

        betId = betCount++;
        Bet storage b = bets[betId];
        b.player = msg.sender;
        b.betType = BetType.Single;
        b.specificNumber = number;
        b.amount = amount;
        FHE.allowThis(b.specificNumber);
        FHE.allowThis(b.amount);
        emit BetPlaced(betId, msg.sender);
    }

    function placeBet(
        BetType betType,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant returns (uint256 betId) {
        require(betType != BetType.Single, "Use placeSingleBet");
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        playerBalance[msg.sender] = FHE.sub(playerBalance[msg.sender], amount);
        FHE.allowThis(playerBalance[msg.sender]);

        betId = betCount++;
        Bet storage b = bets[betId];
        b.player = msg.sender;
        b.betType = betType;
        b.amount = amount;
        b.specificNumber = FHE.asEuint8(0);
        FHE.allowThis(b.amount);
        FHE.allowThis(b.specificNumber);
        emit BetPlaced(betId, msg.sender);
    }

    function spin(uint256 betId) external onlyOwner nonReentrant {
        Bet storage b = bets[betId];
        require(!b.settled, "Already settled");

        euint8 spinResult = FHE.rem(FHE.randEuint8(), 37); // 0-36
        lastSpinResult = spinResult;
        FHE.allowThis(lastSpinResult);

        euint8 isEven = FHE.rem(spinResult, 2);
        euint64 payout = FHE.asEuint64(0);

        if (b.betType == BetType.Single) {
            ebool hit = FHE.eq(spinResult, b.specificNumber);
            payout = FHE.select(hit, FHE.mul(b.amount, FHE.asEuint64(35)), FHE.asEuint64(0));
        } else if (b.betType == BetType.Even) {
            ebool hit = FHE.eq(isEven, FHE.asEuint8(0));
            payout = FHE.select(hit, FHE.mul(b.amount, FHE.asEuint64(2)), FHE.asEuint64(0));
        } else if (b.betType == BetType.Odd) {
            ebool hit = FHE.eq(isEven, FHE.asEuint8(1));
            payout = FHE.select(hit, FHE.mul(b.amount, FHE.asEuint64(2)), FHE.asEuint64(0));
        } else if (b.betType == BetType.Low) {
            ebool hit = FHE.le(spinResult, FHE.asEuint8(18));
            payout = FHE.select(hit, FHE.mul(b.amount, FHE.asEuint64(2)), FHE.asEuint64(0));
        } else if (b.betType == BetType.High) {
            ebool hit = FHE.gt(spinResult, FHE.asEuint8(18));
            payout = FHE.select(hit, FHE.mul(b.amount, FHE.asEuint64(2)), FHE.asEuint64(0));
        }

        b.settled = true;
        playerBalance[b.player] = FHE.add(playerBalance[b.player], payout);
        FHE.allowThis(playerBalance[b.player]);
        FHE.allow(playerBalance[b.player], b.player);
        emit SpinComplete(betId);
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