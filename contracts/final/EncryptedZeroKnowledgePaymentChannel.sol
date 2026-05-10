// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedZeroKnowledgePaymentChannel
/// @notice A Layer-2 style payment channel where channel balances, payment
///         amounts, and nonce values are all managed in FHE. Channel closing
///         uses encrypted final states to prevent balance disputes.
contract EncryptedZeroKnowledgePaymentChannel is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ChannelState { Open, Closing, Closed }

    struct Channel {
        address partyA;
        address partyB;
        euint64 balanceA;          // encrypted balance for party A
        euint64 balanceB;          // encrypted balance for party B
        euint64 totalDeposited;    // total funds locked
        euint32 nonce;             // channel state nonce (encrypted)
        ChannelState state;
        uint256 openedAt;
        uint256 closingAt;
        uint256 disputePeriod;
    }

    mapping(bytes32 => Channel) private channels;
    mapping(address => bytes32[]) public userChannels;
    uint256 public channelCount;

    euint64 private _totalLockedValue;
    uint256 public defaultDisputePeriod = 7 days;

    event ChannelOpened(bytes32 indexed channelId, address partyA, address partyB);
    event PaymentRouted(bytes32 indexed channelId, address from);
    event ChannelClosing(bytes32 indexed channelId);
    event ChannelClosed(bytes32 indexed channelId);

    constructor() Ownable(msg.sender) {
        _totalLockedValue = FHE.asEuint64(0);
        FHE.allowThis(_totalLockedValue);
    }

    function openChannel(
        address partyB,
        externalEuint64 encDepositA, bytes calldata proofA,
        externalEuint64 encDepositB, bytes calldata proofB
    ) external nonReentrant returns (bytes32 channelId) {
        channelId = keccak256(abi.encodePacked(msg.sender, partyB, block.timestamp, channelCount++));
        Channel storage c = channels[channelId];
        c.partyA = msg.sender;
        c.partyB = partyB;
        c.balanceA = FHE.fromExternal(encDepositA, proofA);
        c.balanceB = FHE.fromExternal(encDepositB, proofB);
        c.totalDeposited = FHE.add(c.balanceA, c.balanceB);
        c.nonce = FHE.asEuint32(0);
        c.state = ChannelState.Open;
        c.openedAt = block.timestamp;
        c.disputePeriod = defaultDisputePeriod;
        _totalLockedValue = FHE.add(_totalLockedValue, c.totalDeposited);
        FHE.allowThis(c.balanceA);
        FHE.allow(c.balanceA, msg.sender);
        FHE.allow(c.balanceA, partyB);
        FHE.allowThis(c.balanceB);
        FHE.allow(c.balanceB, msg.sender);
        FHE.allow(c.balanceB, partyB);
        FHE.allowThis(c.totalDeposited);
        FHE.allowThis(c.nonce);
        FHE.allowThis(_totalLockedValue);
        userChannels[msg.sender].push(channelId);
        userChannels[partyB].push(channelId);
        emit ChannelOpened(channelId, msg.sender, partyB);
    }

    function routePayment(
        bytes32 channelId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        Channel storage c = channels[channelId];
        require(c.state == ChannelState.Open, "Channel not open");
        require(msg.sender == c.partyA || msg.sender == c.partyB, "Not participant");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        bool aToB = (msg.sender == c.partyA);
        if (aToB) {
            ebool hasFunds = FHE.le(amount, c.balanceA);
            euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
            c.balanceA = FHE.sub(c.balanceA, actual); // [arithmetic_overflow_underflow]
            euint64 actualScaled = FHE.mul(actual, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            c.balanceB = FHE.add(c.balanceB, actual);
        } else {
            ebool hasFunds = FHE.le(amount, c.balanceB);
            euint64 actual = FHE.select(hasFunds, amount, FHE.asEuint64(0));
            c.balanceB = FHE.sub(c.balanceB, actual);
            c.balanceA = FHE.add(c.balanceA, actual);
        }
        c.nonce = FHE.add(c.nonce, FHE.asEuint32(1));
        FHE.allowThis(c.balanceA);
        FHE.allow(c.balanceA, c.partyA);
        FHE.allow(c.balanceA, c.partyB);
        FHE.allowThis(c.balanceB);
        FHE.allow(c.balanceB, c.partyA);
        FHE.allow(c.balanceB, c.partyB);
        FHE.allowThis(c.nonce);
        emit PaymentRouted(channelId, msg.sender);
    }

    function initiateClose(bytes32 channelId) external {
        Channel storage c = channels[channelId];
        require(c.state == ChannelState.Open, "Not open");
        require(msg.sender == c.partyA || msg.sender == c.partyB, "Not participant");
        c.state = ChannelState.Closing;
        c.closingAt = block.timestamp + c.disputePeriod;
        emit ChannelClosing(channelId);
    }

    function finalizeClose(bytes32 channelId) external nonReentrant {
        Channel storage c = channels[channelId];
        require(c.state == ChannelState.Closing, "Not closing");
        require(block.timestamp >= c.closingAt, "Dispute period active");
        c.state = ChannelState.Closed;
        _totalLockedValue = FHE.sub(_totalLockedValue, c.totalDeposited);
        FHE.allowThis(_totalLockedValue);
        FHE.allow(c.balanceA, c.partyA);
        FHE.allow(c.balanceB, c.partyB);
        emit ChannelClosed(channelId);
    }

    function allowChannelState(bytes32 channelId, address viewer) external {
        Channel storage c = channels[channelId];
        require(msg.sender == c.partyA || msg.sender == c.partyB, "Not participant");
        FHE.allow(c.balanceA, viewer);
        FHE.allow(c.balanceB, viewer);
        FHE.allow(c.nonce, viewer);
    }

    function allowSystemMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalLockedValue, viewer);
    }
}
