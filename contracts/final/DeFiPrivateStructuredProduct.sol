// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiPrivateStructuredProduct
/// @notice Structured financial product with encrypted tranche allocations.
///         Senior, mezzanine, and equity tranches absorb losses in order.
///         Investor exposure in each tranche is hidden from other investors.
contract DeFiPrivateStructuredProduct is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum Tranche { Senior, Mezzanine, Equity }

    struct TrancheInfo {
        euint64 totalCapital;
        euint64 targetYieldBps;
        euint64 lossAbsorbed;
        bool active;
    }

    struct InvestorPosition {
        euint64 invested;
        euint64 yieldAccrued;
        Tranche tranche;
        bool enrolled;
    }

    mapping(Tranche => TrancheInfo) private tranches;
    mapping(address => InvestorPosition) private positions;
    address[] public investors;
    euint64 private _totalAssets;
    euint64 private _reportedYield;
    euint64 private _reportedLoss;

    event TrancheDeposited(address indexed investor, Tranche tranche);
    event YieldDistributed();
    event LossProcessed();

    constructor(
        externalEuint64 encSeniorYield, bytes memory sProof,
        externalEuint64 encMezzYield, bytes memory mProof,
        externalEuint64 encEquityYield, bytes memory eProof
    ) Ownable(msg.sender) {
        tranches[Tranche.Senior].targetYieldBps = FHE.fromExternal(encSeniorYield, sProof);
        tranches[Tranche.Senior].totalCapital = FHE.asEuint64(0);
        tranches[Tranche.Senior].lossAbsorbed = FHE.asEuint64(0);
        tranches[Tranche.Senior].active = true;

        tranches[Tranche.Mezzanine].targetYieldBps = FHE.fromExternal(encMezzYield, mProof);
        tranches[Tranche.Mezzanine].totalCapital = FHE.asEuint64(0);
        tranches[Tranche.Mezzanine].lossAbsorbed = FHE.asEuint64(0);
        tranches[Tranche.Mezzanine].active = true;

        tranches[Tranche.Equity].targetYieldBps = FHE.fromExternal(encEquityYield, eProof);
        tranches[Tranche.Equity].totalCapital = FHE.asEuint64(0);
        tranches[Tranche.Equity].lossAbsorbed = FHE.asEuint64(0);
        tranches[Tranche.Equity].active = true;

        _totalAssets = FHE.asEuint64(0);
        _reportedYield = FHE.asEuint64(0);
        _reportedLoss = FHE.asEuint64(0);

        FHE.allowThis(tranches[Tranche.Senior].targetYieldBps);
        FHE.allowThis(tranches[Tranche.Senior].totalCapital);
        FHE.allowThis(tranches[Tranche.Mezzanine].targetYieldBps);
        FHE.allowThis(tranches[Tranche.Mezzanine].totalCapital);
        FHE.allowThis(tranches[Tranche.Equity].targetYieldBps);
        FHE.allowThis(tranches[Tranche.Equity].totalCapital);
        FHE.allowThis(_totalAssets);
        FHE.allowThis(_reportedYield);
        FHE.allowThis(_reportedLoss);
    }

    function invest(
        Tranche tranche,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        if (!positions[msg.sender].enrolled) {
            positions[msg.sender].yieldAccrued = FHE.asEuint64(0);
            positions[msg.sender].enrolled = true;
            FHE.allowThis(positions[msg.sender].yieldAccrued);
            investors.push(msg.sender);
        }
        positions[msg.sender].invested = FHE.add(positions[msg.sender].invested, amount);
        positions[msg.sender].tranche = tranche;
        tranches[tranche].totalCapital = FHE.add(tranches[tranche].totalCapital, amount);
        _totalAssets = FHE.add(_totalAssets, amount);
        FHE.allowThis(positions[msg.sender].invested);
        FHE.allow(positions[msg.sender].invested, msg.sender);
        FHE.allowThis(tranches[tranche].totalCapital);
        FHE.allowThis(_totalAssets);
        emit TrancheDeposited(msg.sender, tranche);
    }

    function distributeYield(externalEuint64 encYield, bytes calldata proof) external onlyOwner {
        euint64 yield = FHE.fromExternal(encYield, proof);
        _reportedYield = FHE.add(_reportedYield, yield);
        // Senior tranche gets paid first
        euint64 seniorYield = FHE.div(
            ebool _safeMul27 = FHE.le(tranches[Tranche.Senior].totalCapital, FHE.asEuint64(type(uint32).max));
            FHE.mul(tranches[Tranche.Senior].totalCapital, tranches[Tranche.Senior].targetYieldBps),
            10000
        );
        euint64 seniorActual = FHE.select(FHE.ge(yield, seniorYield), seniorYield, yield);
        ebool _safeSub127 = FHE.ge(yield, seniorActual);
        euint64 remaining = FHE.select(_safeSub127, FHE.sub(yield, seniorActual), FHE.asEuint64(0));
        euint64 mezzYield = FHE.div(
            ebool _safeMul28 = FHE.le(tranches[Tranche.Mezzanine].totalCapital, FHE.asEuint64(type(uint32).max));
            FHE.mul(tranches[Tranche.Mezzanine].totalCapital, tranches[Tranche.Mezzanine].targetYieldBps),
            10000
        );
        euint64 mezzActual = FHE.select(FHE.ge(remaining, mezzYield), mezzYield, remaining);
        FHE.allowThis(_reportedYield);
        emit YieldDistributed();
    }

    function processLoss(externalEuint64 encLoss, bytes calldata proof) external onlyOwner {
        euint64 loss = FHE.fromExternal(encLoss, proof);
        _reportedLoss = FHE.add(_reportedLoss, loss);
        // Equity absorbs first
        euint64 equityAbsorb = FHE.select(
            FHE.ge(tranches[Tranche.Equity].totalCapital, loss),
            loss, tranches[Tranche.Equity].totalCapital
        );
        tranches[Tranche.Equity].lossAbsorbed = FHE.add(tranches[Tranche.Equity].lossAbsorbed, equityAbsorb);
        ebool _safeSub128 = FHE.ge(_totalAssets, loss);
        _totalAssets = FHE.select(_safeSub128, FHE.sub(_totalAssets, loss), FHE.asEuint64(0));
        FHE.allowThis(tranches[Tranche.Equity].lossAbsorbed);
        FHE.allowThis(_reportedLoss);
        FHE.allowThis(_totalAssets);
        emit LossProcessed();
    }

    function allowPositionData(address viewer) external {
        FHE.allow(positions[msg.sender].invested, viewer);
        FHE.allow(positions[msg.sender].yieldAccrued, viewer);
    }
}
