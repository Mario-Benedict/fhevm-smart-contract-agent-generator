// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title GamingPredictionMarket_b5_014 - Encrypted prediction market
contract GamingPredictionMarket_b5_014 is ZamaEthereumConfig {
    address public operator;

    struct Market {
        string question;
        euint64 yesPool;
        euint64 noPool;
        bool resolved;
        bool outcome; // true = yes, false = no
        uint256 deadline;
    }

    Market[] public markets;
    mapping(address => mapping(uint256 => euint64)) private yesBets;
    mapping(address => mapping(uint256 => euint64)) private noBets;
    mapping(address => mapping(uint256 => bool)) public claimed;

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor() {
        operator = msg.sender;
    }

    function createMarket(string calldata question, uint256 duration) public onlyOperator returns (uint256) {
        uint256 id = markets.length;
        markets.push(Market({
            question: question,
            yesPool: FHE.asEuint64(0),
            noPool: FHE.asEuint64(0),
            resolved: false,
            outcome: false,
            deadline: block.timestamp + duration
        }));
        FHE.allowThis(markets[id].yesPool);
        FHE.allowThis(markets[id].noPool);
        return id;
    }

    function bet(uint256 marketId, bool yes, externalEuint64 amountStr, bytes calldata proof) public {
        require(marketId < markets.length, "Invalid market");
        Market storage m = markets[marketId];
        require(!m.resolved && block.timestamp < m.deadline, "Market closed");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        if (yes) {
            yesBets[msg.sender][marketId] = FHE.add(yesBets[msg.sender][marketId], amount);
            m.yesPool = FHE.add(m.yesPool, amount);
            FHE.allowThis(yesBets[msg.sender][marketId]);
            FHE.allowThis(m.yesPool);
        } else {
            noBets[msg.sender][marketId] = FHE.add(noBets[msg.sender][marketId], amount);
            m.noPool = FHE.add(m.noPool, amount);
            FHE.allowThis(noBets[msg.sender][marketId]);
            FHE.allowThis(m.noPool);
        }
    }

    function resolve(uint256 marketId, bool outcome) public onlyOperator {
        markets[marketId].resolved = true;
        markets[marketId].outcome = outcome;
    }

    function claim(uint256 marketId) public {
        require(markets[marketId].resolved, "Not resolved");
        require(!claimed[msg.sender][marketId], "Already claimed");
        claimed[msg.sender][marketId] = true;
        bool outcome = markets[marketId].outcome;
        euint64 myBet = outcome ? yesBets[msg.sender][marketId] : noBets[msg.sender][marketId];
        euint64 totalPool = FHE.add(markets[marketId].yesPool, markets[marketId].noPool);
        euint64 winPool = outcome ? markets[marketId].yesPool : markets[marketId].noPool;
        ebool hasBet = FHE.gt(myBet, FHE.asEuint64(0));
        // payout = myBet * totalPool / winPool (simplified as 2x)
        euint64 payout = FHE.select(hasBet, FHE.add(myBet, myBet), FHE.asEuint64(0));
        FHE.allow(payout, msg.sender);
        FHE.allowThis(totalPool);
        FHE.allowThis(winPool);
    }

    function allowPools(uint256 marketId, address viewer) public onlyOperator {
        FHE.allow(markets[marketId].yesPool, viewer);
        FHE.allow(markets[marketId].noPool, viewer);
    }
}
