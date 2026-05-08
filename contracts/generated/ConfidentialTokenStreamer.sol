// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialTokenStreamer is ZamaEthereumConfig, Ownable {
    IERC20 public immutable paymentToken;

    struct SalaryStream {
        euint64 encryptedTotalAllocation;
        euint64 encryptedSalaryPerSecond;
        euint64 encryptedAmountWithdrawn;
        uint256 startTime;
        uint256 stopTime;
        bool exists;
    }

    mapping(address => SalaryStream) private streams;

    event StreamCreated(address indexed employee);
    event SalaryWithdrawn(address indexed employee);

    constructor(address _paymentToken) Ownable(msg.sender) {
        paymentToken = IERC20(_paymentToken);
    }

    function createEncryptedStream(
        address employee,
        externalEuint64 memory extTotal,
        externalEuint64 memory extRatePerSec,
        bytes calldata proofTotal,
        bytes calldata proofRate,
        uint256 durationSeconds
    ) external onlyOwner {
        require(!streams[employee].exists, "Stream exists");

        euint64 total = FHE.fromExternal(extTotal, proofTotal);
        euint64 rate = FHE.fromExternal(extRatePerSec, proofRate);
        euint64 withdrawn = FHE.asEuint64(0);

        FHE.allowThis(total);
        FHE.allowThis(rate);
        FHE.allowThis(withdrawn);

        streams[employee] = SalaryStream({
            encryptedTotalAllocation: total,
            encryptedSalaryPerSecond: rate,
            encryptedAmountWithdrawn: withdrawn,
            startTime: block.timestamp,
            stopTime: block.timestamp + durationSeconds,
            exists: true
        });

        // Pull maximum plaintext liquidity into the contract
        uint64 maxLiability = FHE.decrypt(total);
        require(paymentToken.transferFrom(msg.sender, address(this), maxLiability), "Funding failed");

        emit StreamCreated(employee);
    }

    function withdrawStreamedSalary(
        externalEuint64 memory extAmount,
        bytes calldata proofAmount
    ) external {
        SalaryStream storage stream = streams[msg.sender];
        require(stream.exists, "No active stream");

        euint64 requestedAmount = FHE.fromExternal(extAmount, proofAmount);
        FHE.allowThis(requestedAmount);

        // 1. Calculate time elapsed
        uint256 timeElapsed;
        if (block.timestamp >= stream.stopTime) {
            timeElapsed = stream.stopTime - stream.startTime;
        } else {
            timeElapsed = block.timestamp - stream.startTime;
        }

        // 2. Calculate theoretically available salary: (timeElapsed * rate)
        euint64 timeMultiplier = FHE.asEuint64(timeElapsed);
        euint64 earnedTotal = FHE.mul(stream.encryptedSalaryPerSecond, timeMultiplier);
        
        // 3. Cap earned total by the total allocation to prevent over-streaming
        ebool isOverAllocation = FHE.gt(earnedTotal, stream.encryptedTotalAllocation);
        euint64 actualEarned = FHE.select(isOverAllocation, stream.encryptedTotalAllocation, earnedTotal);
        FHE.allowThis(actualEarned);

        // 4. Calculate what is left to withdraw right now: (actualEarned - withdrawn)
        euint64 currentlyClaimable = FHE.sub(actualEarned, stream.encryptedAmountWithdrawn);
        FHE.allowThis(currentlyClaimable);

        // 5. Ensure requested amount <= currently claimable
        ebool canWithdraw = FHE.ge(currentlyClaimable, requestedAmount);
        FHE.req(canWithdraw);

        // 6. Update state
        stream.encryptedAmountWithdrawn = FHE.add(stream.encryptedAmountWithdrawn, requestedAmount);
        FHE.allowThis(stream.encryptedAmountWithdrawn);

        // 7. Decrypt specifically what was requested and transfer
        uint64 decryptedTransfer = FHE.decrypt(requestedAmount);
        require(paymentToken.transfer(msg.sender, decryptedTransfer), "Transfer failed");

        emit SalaryWithdrawn(msg.sender);
    }
}