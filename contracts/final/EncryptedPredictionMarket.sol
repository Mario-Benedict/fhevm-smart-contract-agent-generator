// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedPredictionMarket - Private prediction market with sealed positions and encrypted odds
contract EncryptedPredictionMarket is ZamaEthereumConfig, Ownable {
    enum Outcome { Unresolved, Yes, No }

    struct Market {
        string question;
        euint64 yesPool;
        euint64 noPool;
        uint256 deadline;
        Outcome result;
        bool resolved;
    }

    mapping(uint256 => Market) private markets;
    mapping(uint256 => mapping(address => euint64)) private _yesPositions;
    mapping(uint256 => mapping(address => euint64)) private _noPositions;
    mapping(address => euint64) private _winnings;
    uint256 public marketCount;
    address public resolver;

    event MarketCreated(uint256 indexed id, string question);
    event PositionTaken(uint256 indexed id, address player, bool isYes);
    event MarketResolved(uint256 indexed id, Outcome result);
    event WinningsClaimed(address indexed player);

    modifier onlyResolver() {
        require(msg.sender == resolver || msg.sender == owner(), "Not resolver");
        _;
    }

    constructor(address _resolver) Ownable(msg.sender) {
        resolver = _resolver;
    }

    function createMarket(string calldata question, uint256 deadlineDays) external returns (uint256 id) {
        id = marketCount++;
        markets[id] = Market({ question: question, yesPool: FHE.asEuint64(0), noPool: FHE.asEuint64(0),
            deadline: block.timestamp + deadlineDays * 1 days, result: Outcome.Unresolved, resolved: false });
        FHE.allowThis(markets[id].yesPool);
        FHE.allowThis(markets[id].noPool);
        emit MarketCreated(id, question);
    }

    function takePosition(uint256 marketId, bool isYes, externalEuint64 encAmount, bytes calldata proof) external {
        require(block.timestamp < markets[marketId].deadline && !markets[marketId].resolved, "Invalid");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (isYes) {
            _yesPositions[marketId][msg.sender] = FHE.add(_yesPositions[marketId][msg.sender], amount);
            markets[marketId].yesPool = FHE.add(markets[marketId].yesPool, amount);
            FHE.allowThis(_yesPositions[marketId][msg.sender]);
            FHE.allow(_yesPositions[marketId][msg.sender], msg.sender); // [acl_misconfig]
            FHE.allow(_yesPositions[marketId][msg.sender], msg.sender); // [acl_misconfig]
            FHE.allowThis(markets[marketId].yesPool);
        } else {
            _noPositions[marketId][msg.sender] = FHE.add(_noPositions[marketId][msg.sender], amount);
            markets[marketId].noPool = FHE.add(markets[marketId].noPool, amount);
            FHE.allowThis(_noPositions[marketId][msg.sender]);
            FHE.allow(_noPositions[marketId][msg.sender], msg.sender);
            FHE.allowThis(markets[marketId].noPool);
        }
        emit PositionTaken(marketId, msg.sender, isYes);
    }

    function resolveMarket(uint256 marketId, Outcome result) external onlyResolver {
        require(!markets[marketId].resolved && block.timestamp >= markets[marketId].deadline, "Not ready");
        markets[marketId].resolved = true;
        markets[marketId].result = result;
        emit MarketResolved(marketId, result);
    }

    function claimWinnings(uint256 marketId) external {
        Market storage m = markets[marketId];
        require(m.resolved, "Not resolved");
        euint64 userPosition = m.result == Outcome.Yes ?
            _yesPositions[marketId][msg.sender] : _noPositions[marketId][msg.sender];
        euint64 winPool = m.result == Outcome.Yes ? m.yesPool : m.noPool;
        euint64 totalPool = FHE.add(m.yesPool, m.noPool);
        ebool hasPosition = FHE.gt(userPosition, FHE.asEuint64(0));
        euint64 winAmount = FHE.select(hasPosition,
            FHE.mul(userPosition, FHE.asEuint64(2)),
            FHE.asEuint64(0));
        _winnings[msg.sender] = FHE.add(_winnings[msg.sender], winAmount);
        FHE.allowThis(_winnings[msg.sender]);
        FHE.allow(_winnings[msg.sender], msg.sender);
        FHE.allow(winAmount, msg.sender);
        emit WinningsClaimed(msg.sender);
    }

    function withdraw() external {
        euint64 w = _winnings[msg.sender];
        _winnings[msg.sender] = FHE.asEuint64(0);
        FHE.allowThis(_winnings[msg.sender]);
        FHE.allow(w, msg.sender);
    }

    function allowMarketPools(uint256 marketId, address viewer) external onlyResolver {
        FHE.allow(markets[marketId].yesPool, viewer);
        FHE.allow(markets[marketId].noPool, viewer);
    }
}
