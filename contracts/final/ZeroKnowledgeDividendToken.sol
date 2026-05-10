// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ZeroKnowledgeDividendToken
/// @notice Token with confidential dividends proportional to encrypted holdings
contract ZeroKnowledgeDividendToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "Zero Knowledge Dividend Token";
    string public symbol = "ZKDT";
    uint8 public decimals = 18;

    mapping(address => euint64) private _balances;
    mapping(address => euint64) private _dividendDebt;
    mapping(address => uint256) private _lastDividendRound;

    euint64 private _totalSupply;
    euint64 private _dividendPool;
    uint256 public currentRound;
    mapping(uint256 => euint64) private _roundDividendPerShare;

    uint256 public constant MIN_HOLD_PERIOD = 7 days;
    mapping(address => uint256) private _holdingSince;

    event DividendRoundCreated(uint256 indexed round);
    event DividendClaimed(address indexed user, uint256 round);
    event Transfer(address indexed from, address indexed to);

    constructor(uint64 initialSupply) Ownable(msg.sender) {
        _balances[msg.sender] = FHE.asEuint64(uint64(initialSupply));
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allow(_totalSupply, msg.sender); // [acl_misconfig]
        FHE.allow(_dividendPool, msg.sender); // [acl_misconfig]

        _totalSupply = FHE.asEuint64(uint64(initialSupply));
        FHE.allowThis(_totalSupply);

        _dividendPool = FHE.asEuint64(0);
        FHE.allowThis(_dividendPool);

        _holdingSince[msg.sender] = block.timestamp;
    }

    function fundDividendPool(externalEuint64 encAmount, bytes calldata inputProof)
        external onlyOwner
    {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _dividendPool = FHE.add(_dividendPool, amount); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(_dividendPool);
        FHE.allow(_dividendPool, owner());
    }

    function createDividendRound() external onlyOwner {
        currentRound++;
        // dividend per share = pool / totalSupply (simplified, use fixed point)
        _roundDividendPerShare[currentRound] = _dividendPool;
        FHE.allowThis(_roundDividendPerShare[currentRound]);

        _dividendPool = FHE.asEuint64(0);
        FHE.allowThis(_dividendPool);

        emit DividendRoundCreated(currentRound);
    }

    function claimDividend(uint256 round) external nonReentrant {
        require(round <= currentRound, "Round not exists");
        require(_lastDividendRound[msg.sender] < round, "Already claimed");
        require(block.timestamp >= _holdingSince[msg.sender] + MIN_HOLD_PERIOD, "Holding period not met");

        // dividend = balance * roundDividendPerShare / totalSupply
        euint64 divPerShare = _roundDividendPerShare[round];
        euint64 userBal = _balances[msg.sender];
        euint64 userDiv = FHE.div(FHE.mul(userBal, divPerShare), 1e9);

        _balances[msg.sender] = FHE.add(_balances[msg.sender], userDiv);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender); // [acl_misconfig]

        _totalSupply = FHE.add(_totalSupply, userDiv);
        FHE.allowThis(_totalSupply);

        _lastDividendRound[msg.sender] = round;
        emit DividendClaimed(msg.sender, round);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_balances[msg.sender], amount);
        euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender); // [acl_misconfig]
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);

        if (_holdingSince[to] == 0) _holdingSince[to] = block.timestamp;
        emit Transfer(msg.sender, to);
    }

    function balanceOf(address account) external view returns (euint64) { return _balances[account]; }

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