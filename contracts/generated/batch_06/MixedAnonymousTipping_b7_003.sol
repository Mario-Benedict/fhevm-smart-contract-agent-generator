// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedAnonymousTipping_b7_003 - Anonymous tipping/donation with encrypted amounts
contract MixedAnonymousTipping_b7_003 is ZamaEthereumConfig {
    address public owner;

    struct Creator {
        string name;
        euint64 totalTips;
        uint256 tipCount;
        bool active;
    }

    mapping(address => Creator) private creators;
    address[] public creatorList;
    euint64 private platformFee;
    uint8 public platformFeePercent;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint8 _feePercent) {
        require(_feePercent <= 10, "Max 10%");
        owner = msg.sender;
        platformFeePercent = _feePercent;
        platformFee = FHE.asEuint64(0);
        FHE.allowThis(platformFee);
    }

    function registerCreator(address creator, string calldata name) public onlyOwner {
        creators[creator] = Creator({ name: name, totalTips: FHE.asEuint64(0), tipCount: 0, active: true });
        FHE.allowThis(creators[creator].totalTips);
        creatorList.push(creator);
    }

    function tip(address creator, externalEuint64 amountStr, bytes calldata proof) public {
        require(creators[creator].active, "Creator not active");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        euint64 fee = FHE.mul(amount, FHE.asEuint64(uint64(platformFeePercent)));
        euint64 net = FHE.sub(amount, fee);
        creators[creator].totalTips = FHE.add(creators[creator].totalTips, net);
        creators[creator].tipCount++;
        platformFee = FHE.add(platformFee, fee);
        FHE.allowThis(creators[creator].totalTips);
        FHE.allowThis(platformFee);
    }

    function withdrawTips(address creator) public {
        require(msg.sender == creator, "Not creator");
        euint64 tips = creators[creator].totalTips;
        creators[creator].totalTips = FHE.asEuint64(0);
        FHE.allowThis(creators[creator].totalTips);
        FHE.allow(tips, creator);
    }

    function collectPlatformFee() public onlyOwner {
        FHE.allow(platformFee, owner);
        platformFee = FHE.asEuint64(0);
        FHE.allowThis(platformFee);
    }

    function allowCreatorTips(address creator, address viewer) public onlyOwner {
        FHE.allow(creators[creator].totalTips, viewer);
    }

    function getCreatorCount() public view returns (uint256) {
        return creatorList.length;
    }
}
