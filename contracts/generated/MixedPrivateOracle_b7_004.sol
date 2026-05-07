// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedPrivateOracle_b7_004 - Confidential oracle data feeding
contract MixedPrivateOracle_b7_004 is ZamaEthereumConfig {
    address public owner;

    struct DataFeed {
        string symbol;
        euint64 latestValue;
        uint256 lastUpdated;
        uint8 decimals;
        bool active;
    }

    mapping(bytes32 => DataFeed) private feeds;
    mapping(address => bool) public isOracle;

    modifier onlyOracle() {
        require(isOracle[msg.sender] || msg.sender == owner, "Not oracle");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        isOracle[msg.sender] = true;
    }

    function addOracle(address oracle) public onlyOwner {
        isOracle[oracle] = true;
    }

    function removeOracle(address oracle) public onlyOwner {
        isOracle[oracle] = false;
    }

    function createFeed(string calldata symbol, uint8 decimals) public onlyOwner returns (bytes32) {
        bytes32 feedId = keccak256(abi.encodePacked(symbol));
        feeds[feedId] = DataFeed({
            symbol: symbol,
            latestValue: FHE.asEuint64(0),
            lastUpdated: 0,
            decimals: decimals,
            active: true
        });
        FHE.allowThis(feeds[feedId].latestValue);
        return feedId;
    }

    function updateFeed(bytes32 feedId, externalEuint64 valueStr, bytes calldata proof) public onlyOracle {
        require(feeds[feedId].active, "Feed not active");
        euint64 value = FHE.fromExternal(valueStr, proof);
        feeds[feedId].latestValue = value;
        feeds[feedId].lastUpdated = block.timestamp;
        FHE.allowThis(feeds[feedId].latestValue);
    }

    function grantFeedAccess(bytes32 feedId, address consumer) public onlyOwner {
        FHE.allow(feeds[feedId].latestValue, consumer);
    }

    function deactivateFeed(bytes32 feedId) public onlyOwner {
        feeds[feedId].active = false;
    }

    function getFeedLastUpdated(bytes32 feedId) public view returns (uint256) {
        return feeds[feedId].lastUpdated;
    }
}
