// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialLoyaltyPoints_b11_009 is ZamaEthereumConfig {
    address public merchant;
    mapping(address => euint64) private points;

    constructor() { merchant = msg.sender; }

    function earnPoints(address user, externalEuint64 pointsStr, bytes calldata proof) public {
        require(msg.sender == merchant, "Not merchant");
        euint64 amount = FHE.fromExternal(pointsStr, proof);
        points[user] = FHE.add(points[user], amount);
        FHE.allowThis(points[user]);
    }

    function burnPoints(externalEuint64 pointsStr, bytes calldata proof) public returns (ebool) {
        euint64 toBurn = FHE.fromExternal(pointsStr, proof);
        ebool sufficient = FHE.ge(points[msg.sender], toBurn);
        
        euint64 deducted = FHE.select(sufficient, toBurn, FHE.asEuint64(0));
        ebool _safeSub46 = FHE.ge(points[msg.sender], deducted);
        points[msg.sender] = FHE.select(_safeSub46, FHE.sub(points[msg.sender], deducted), FHE.asEuint64(0));
        
        FHE.allowThis(points[msg.sender]);
        return sufficient;
    }
}
