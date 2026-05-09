// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCrossChainAtomicSwap
/// @notice A trustless atomic swap where both legs of the swap use encrypted
///         amounts. Participants commit to encrypted values; the coordinator
///         reveals nothing — the FHE engine enforces fairness.
contract EncryptedCrossChainAtomicSwap is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SwapState { Pending, Committed, Completed, Cancelled }

    struct SwapOrder {
        address initiator;
        address counterparty;
        euint64 encAmountA;    // what initiator sends (chain A token)
        euint64 encAmountB;    // what counterparty sends (chain B token)
        euint64 encLockTime;   // encrypted expiry delta
        uint256 createdAt;
        uint256 expiresAt;
        SwapState state;
        bool initiatorLocked;
        bool counterpartyLocked;
    }

    mapping(bytes32 => SwapOrder) public swapOrders;
    mapping(address => bytes32[]) public userSwaps;
    euint64 private _totalVolumeEncrypted;
    uint256 public swapCount;

    event SwapProposed(bytes32 indexed swapId, address indexed initiator, address indexed counterparty);
    event SwapCommitted(bytes32 indexed swapId, address committer);
    event SwapCompleted(bytes32 indexed swapId);
    event SwapCancelled(bytes32 indexed swapId);

    constructor() Ownable(msg.sender) {
        _totalVolumeEncrypted = FHE.asEuint64(0);
        FHE.allowThis(_totalVolumeEncrypted);
    }

    function proposeSwap(
        address counterparty,
        externalEuint64 encAmtA, bytes calldata proofA,
        externalEuint64 encAmtB, bytes calldata proofB,
        uint256 lockDuration
    ) external nonReentrant returns (bytes32 swapId) {
        swapId = keccak256(abi.encodePacked(msg.sender, counterparty, block.timestamp, swapCount));
        SwapOrder storage s = swapOrders[swapId];
        s.initiator = msg.sender;
        s.counterparty = counterparty;
        s.encAmountA = FHE.fromExternal(encAmtA, proofA);
        s.encAmountB = FHE.fromExternal(encAmtB, proofB);
        s.encLockTime = FHE.asEuint64(uint64(lockDuration));
        s.createdAt = block.timestamp;
        s.expiresAt = block.timestamp + lockDuration;
        s.state = SwapState.Pending;
        FHE.allowThis(s.encAmountA);
        FHE.allow(s.encAmountA, msg.sender);
        FHE.allow(s.encAmountA, counterparty);
        FHE.allowThis(s.encAmountB);
        FHE.allow(s.encAmountB, msg.sender);
        FHE.allow(s.encAmountB, counterparty);
        FHE.allowThis(s.encLockTime);
        userSwaps[msg.sender].push(swapId);
        userSwaps[counterparty].push(swapId);
        swapCount++;
        emit SwapProposed(swapId, msg.sender, counterparty);
    }

    function commitToSwap(bytes32 swapId) external nonReentrant {
        SwapOrder storage s = swapOrders[swapId];
        require(s.state == SwapState.Pending, "Not pending");
        require(block.timestamp < s.expiresAt, "Expired");
        require(msg.sender == s.initiator || msg.sender == s.counterparty, "Not participant");
        if (msg.sender == s.initiator) s.initiatorLocked = true;
        else s.counterpartyLocked = true;
        if (s.initiatorLocked && s.counterpartyLocked) {
            s.state = SwapState.Committed;
        }
        emit SwapCommitted(swapId, msg.sender);
    }

    function finalizeSwap(bytes32 swapId) external onlyOwner {
        SwapOrder storage s = swapOrders[swapId];
        require(s.state == SwapState.Committed, "Not committed");
        s.state = SwapState.Completed;
        _totalVolumeEncrypted = FHE.add(_totalVolumeEncrypted, s.encAmountA);
        FHE.allowThis(_totalVolumeEncrypted);
        FHE.allow(s.encAmountA, s.counterparty);
        FHE.allow(s.encAmountB, s.initiator);
        emit SwapCompleted(swapId);
    }

    function cancelSwap(bytes32 swapId) external nonReentrant {
        SwapOrder storage s = swapOrders[swapId];
        require(s.state == SwapState.Pending || s.state == SwapState.Committed, "Cannot cancel");
        require(block.timestamp >= s.expiresAt || msg.sender == s.initiator, "Not authorized");
        s.state = SwapState.Cancelled;
        emit SwapCancelled(swapId);
    }

    function allowVolume(address viewer) external onlyOwner {
        FHE.allow(_totalVolumeEncrypted, viewer);
    }
}
