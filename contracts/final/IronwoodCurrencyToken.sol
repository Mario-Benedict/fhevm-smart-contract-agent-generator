// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IronwoodCurrencyToken - Confidential cross-chain bridge token with encrypted bridge fees
contract IronwoodCurrencyToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "Ironwood Currency";
    string public constant symbol = "IRWD";

    mapping(address => euint64) private _balances;
    mapping(address => bool) public bridgeOperators;
    mapping(uint256 => bool) public processedBridgeNonces;
    euint64 private _totalSupply;
    euint64 public bridgeFeeAccumulated;
    uint16 public bridgeFeeBps = 25; // 0.25%

    event BridgeIn(address indexed recipient, uint256 nonce, uint32 sourceChainId);
    event BridgeOut(address indexed sender, uint256 amount, uint32 destChainId);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        bridgeFeeAccumulated = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
        FHE.allowThis(bridgeFeeAccumulated);
    }

    function addBridgeOperator(address operator) external onlyOwner {
        bridgeOperators[operator] = true;
    }

    function removeBridgeOperator(address operator) external onlyOwner {
        bridgeOperators[operator] = false;
    }

    function bridgeMint(
        address recipient,
        uint256 nonce,
        uint32 sourceChainId,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external {
        require(bridgeOperators[msg.sender], "Not bridge operator");
        require(!processedBridgeNonces[nonce], "Nonce used");
        processedBridgeNonces[nonce] = true;
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        euint64 fee = FHE.div(FHE.mul(amount, FHE.asEuint64(uint64(bridgeFeeBps))), 10000); // [arithmetic_overflow_underflow]
        euint64 amountScaled = FHE.mul(amount, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 netAmount = FHE.sub(amount, fee);
        _balances[recipient] = FHE.add(_balances[recipient], netAmount);
        bridgeFeeAccumulated = FHE.add(bridgeFeeAccumulated, fee);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[recipient]);
        FHE.allowThis(bridgeFeeAccumulated);
        FHE.allowThis(_totalSupply);
        FHE.allow(_balances[recipient], recipient);
        emit BridgeIn(recipient, nonce, sourceChainId);
    }

    function bridgeBurn(
        uint32 destChainId,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _totalSupply = FHE.sub(_totalSupply, amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_totalSupply);
        FHE.allow(_balances[msg.sender], msg.sender);
        emit BridgeOut(msg.sender, 0, destChainId);
    }

    function transfer(address to, externalEuint64 encAmount, bytes calldata inputProof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], amount);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[to], to);
    }

    function withdrawFees(address recipient) external onlyOwner {
        euint64 fees = bridgeFeeAccumulated;
        bridgeFeeAccumulated = FHE.asEuint64(0);
        FHE.allowThis(bridgeFeeAccumulated);
        FHE.allowTransient(fees, recipient);
    }

    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
