// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract DaoTreasuryRisk_b11_010 is ZamaEthereumConfig {
    address public riskManager;
    euint64 private maxInvestmentLimit;

    constructor() {
        riskManager = msg.sender;
        maxInvestmentLimit = FHE.asEuint64(0);
        FHE.allowThis(maxInvestmentLimit);
    }

    function setRiskLimit(externalEuint64 limitStr, bytes calldata proof) public {
        require(msg.sender == riskManager, "Not risk manager");
        maxInvestmentLimit = FHE.fromExternal(limitStr, proof);
        FHE.allowThis(maxInvestmentLimit);
    }

    function proposeInvestment(externalEuint64 amountStr, bytes calldata proof) public returns (ebool) {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        ebool isWithinLimit = FHE.le(amount, maxInvestmentLimit);
        return isWithinLimit;
    }
}
