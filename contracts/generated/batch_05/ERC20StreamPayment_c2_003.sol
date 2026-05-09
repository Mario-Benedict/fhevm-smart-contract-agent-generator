// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20StreamPayment_c2_003
/// @notice Real-world salary streaming: employer creates a stream of encrypted
///         tokens flowing to employee per-second. Employee can withdraw anytime.
contract ERC20StreamPayment_c2_003 is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public name = "StreamPay Token";
    string public symbol = "SPT";

    struct Stream {
        address sender;
        address recipient;
        euint64 ratePerSecond;    // encrypted rate
        euint64 depositedAmount;  // total deposited
        euint64 withdrawnAmount;  // already withdrawn
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    mapping(uint256 => Stream) private streams;
    mapping(address => euint64) private _balances;
    uint256 public nextStreamId;
    euint64 private _totalSupply;

    event StreamCreated(uint256 indexed streamId, address sender, address recipient);
    event StreamCancelled(uint256 indexed streamId);
    event Withdrawal(uint256 indexed streamId, address recipient);

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply);
    }

    function mint(address to, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _balances[to] = FHE.add(_balances[to], amount);
        _totalSupply = FHE.add(_totalSupply, amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allowThis(_totalSupply);
    }

    function createStream(
        address recipient,
        externalEuint64 encDeposit, bytes calldata depositProof,
        externalEuint64 encRate, bytes calldata rateProof,
        uint256 durationSeconds
    ) external nonReentrant returns (uint256 streamId) {
        euint64 deposit = FHE.fromExternal(encDeposit, depositProof);
        euint64 rate = FHE.fromExternal(encRate, rateProof);
        ebool hasFunds = FHE.le(deposit, _balances[msg.sender]);
        euint64 actualDeposit = FHE.select(hasFunds, deposit, FHE.asEuint64(0));
        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actualDeposit);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);

        streamId = nextStreamId++;
        streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient,
            ratePerSecond: rate,
            depositedAmount: actualDeposit,
            withdrawnAmount: FHE.asEuint64(0),
            startTime: block.timestamp,
            endTime: block.timestamp + durationSeconds,
            active: true
        });
        FHE.allowThis(streams[streamId].ratePerSecond);
        FHE.allowThis(streams[streamId].depositedAmount);
        FHE.allowThis(streams[streamId].withdrawnAmount);
        FHE.allow(streams[streamId].ratePerSecond, recipient);
        FHE.allow(streams[streamId].depositedAmount, recipient);
        emit StreamCreated(streamId, msg.sender, recipient);
    }

    function withdrawFromStream(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        require(s.active && s.recipient == msg.sender, "Not your stream");
        uint256 elapsed = block.timestamp < s.endTime ? block.timestamp - s.startTime : s.endTime - s.startTime;
        euint64 earned = FHE.mul(s.ratePerSecond, FHE.asEuint64(uint64(elapsed)));
        euint64 available = FHE.sub(
            FHE.select(FHE.le(earned, s.depositedAmount), earned, s.depositedAmount),
            s.withdrawnAmount
        );
        s.withdrawnAmount = FHE.add(s.withdrawnAmount, available);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], available);
        FHE.allowThis(s.withdrawnAmount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        emit Withdrawal(streamId, msg.sender);
    }

    function cancelStream(uint256 streamId) external nonReentrant {
        Stream storage s = streams[streamId];
        require(s.active && s.sender == msg.sender, "Not your stream");
        s.active = false;
        // Refund unstreamed amount
        euint64 unstreamed = FHE.sub(s.depositedAmount, s.withdrawnAmount);
        _balances[msg.sender] = FHE.add(_balances[msg.sender], unstreamed);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        emit StreamCancelled(streamId);
    }

    function allowBalance(address viewer) external {
        FHE.allow(_balances[msg.sender], viewer);
    }
}
