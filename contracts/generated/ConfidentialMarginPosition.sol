// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialMarginPosition is ZamaEthereumConfig, Ownable {
    IERC20 public immutable collateralToken;
    IERC20 public immutable debtToken;

    struct Position {
        euint64 encryptedCollateral;
        euint64 encryptedDebt;
        bool isActive;
    }

    mapping(address => Position) private positions;
    euint32 private currentEncryptedPrice; // Oracle price of collateral in terms of debt

    constructor(address _collateral, address _debt) Ownable(msg.sender) {
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
        currentEncryptedPrice = FHE.asEuint32(0);
        FHE.allowThis(currentEncryptedPrice);
    }

    function updateOraclePrice(externalEuint32 memory extPrice, bytes calldata proof) external onlyOwner {
        currentEncryptedPrice = FHE.fromExternal(extPrice, proof);
        FHE.allowThis(currentEncryptedPrice);
    }

    function adjustPosition(
        externalEuint64 memory extAddCollateral,
        externalEuint64 memory extAddDebt,
        bytes calldata proofCol,
        bytes calldata proofDebt
    ) external {
        euint64 addCol = FHE.fromExternal(extAddCollateral, proofCol);
        euint64 addDebt = FHE.fromExternal(extAddDebt, proofDebt);
        
        FHE.allowThis(addCol);
        FHE.allowThis(addDebt);

        if (!positions[msg.sender].isActive) {
            positions[msg.sender] = Position(FHE.asEuint64(0), FHE.asEuint64(0), true);
            FHE.allowThis(positions[msg.sender].encryptedCollateral);
            FHE.allowThis(positions[msg.sender].encryptedDebt);
        }

        positions[msg.sender].encryptedCollateral = FHE.add(positions[msg.sender].encryptedCollateral, addCol);
        positions[msg.sender].encryptedDebt = FHE.add(positions[msg.sender].encryptedDebt, addDebt);

        FHE.allowThis(positions[msg.sender].encryptedCollateral);
        FHE.allowThis(positions[msg.sender].encryptedDebt);

        // Required Collateral Value = Debt * 150% (Health factor 1.5)
        euint64 reqColValue = FHE.div(FHE.mul(positions[msg.sender].encryptedDebt, FHE.asEuint64(150)), 100);
        
        // Actual Collateral Value = Collateral * Price
        euint64 encPrice64 = FHE.asEuint64(currentEncryptedPrice);
        euint64 actualColValue = FHE.mul(positions[msg.sender].encryptedCollateral, encPrice64);
        
        FHE.allowThis(reqColValue);
        FHE.allowThis(actualColValue);

        ebool isHealthy = FHE.ge(actualColValue, reqColValue);
        FHE.req(isHealthy);

        uint64 pAddCol = FHE.decrypt(addCol);
        uint64 pAddDebt = FHE.decrypt(addDebt);

        if (pAddCol > 0) require(collateralToken.transferFrom(msg.sender, address(this), pAddCol), "Col fail");
        if (pAddDebt > 0) require(debtToken.transfer(msg.sender, pAddDebt), "Debt fail");
    }

    function liquidate(address user) external {
        require(positions[user].isActive, "No position");

        euint64 reqColValue = FHE.div(FHE.mul(positions[user].encryptedDebt, FHE.asEuint64(110)), 100); // 110% liquidation threshold
        euint64 encPrice64 = FHE.asEuint64(currentEncryptedPrice);
        euint64 actualColValue = FHE.mul(positions[user].encryptedCollateral, encPrice64);

        ebool canLiquidate = FHE.lt(actualColValue, reqColValue);
        FHE.req(canLiquidate);

        uint64 seizeAmount = FHE.decrypt(positions[user].encryptedCollateral);
        positions[user].isActive = false;

        require(collateralToken.transfer(msg.sender, seizeAmount), "Seize failed");
    }
}