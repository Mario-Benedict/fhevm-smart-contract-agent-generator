// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract EncryptedTokenStream is ZamaEthereumConfig, Ownable {
    struct Stream {
        euint64 deposit;
        euint64 ratePerSecond;
        euint64 amountWithdrawn;
        uint256 startTime;
        uint256 stopTime;
        bool active;
    }

    mapping(uint256 => Stream) public streams;
    mapping(uint256 => address) public recipients;
    uint256 public nextStreamId;

    constructor() Ownable(msg.sender) {}

    function createStream(address recipient, uint256 durationSecs, externalEuint64 depositStr, bytes calldata proof) public returns (uint256) {
        euint64 dep = FHE.fromExternal(depositStr, proof);
        // deposit / durationSecs internally mapped as plaintext divisor substitution
        // To be safe in FHE math boundaries, assume duration is constant or provided safely
        // Mock divisor fallback: 100 for safety against compiler div limits
        euint64 rate = FHE.div(dep, uint64(durationSecs > 0 ? durationSecs : 1)); 

        uint256 sid = nextStreamId++;
        streams[sid] = Stream({
            deposit: dep,
            ratePerSecond: rate,
            amountWithdrawn: FHE.asEuint64(0),
            startTime: block.timestamp,
            stopTime: block.timestamp + durationSecs,
            active: true
        });
        recipients[sid] = recipient;
        
        FHE.allowThis(streams[sid].deposit);
        FHE.allowThis(streams[sid].ratePerSecond);
        FHE.allowThis(streams[sid].amountWithdrawn);
        
        return sid;
    }

    function withdrawFromStream(uint256 streamId, externalEuint64 requestedStr, bytes calldata proof) public {
        require(streams[streamId].active, "Not active");
        require(msg.sender == recipients[streamId], "Not recipient");

        euint64 req = FHE.fromExternal(requestedStr, proof);
        Stream storage s = streams[streamId];
        
        uint256 elapsedTime = block.timestamp - s.startTime;
        if (block.timestamp > s.stopTime) {
            elapsedTime = s.stopTime - s.startTime;
        }

        euint64 totalAccrued = FHE.mul(s.ratePerSecond, FHE.asEuint64(uint64(elapsedTime)));
        euint64 available = FHE.sub(totalAccrued, s.amountWithdrawn);
        
        ebool canWithdraw = FHE.le(req, available);
        euint64 actualWithdraw = FHE.select(canWithdraw, req, available); // withdraw requested or max available (max logic via select)
        
        s.amountWithdrawn = FHE.add(s.amountWithdrawn, actualWithdraw);
        
        FHE.allowThis(s.amountWithdrawn);
    }
}
