// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedInterestRateSwap - OTC interest rate swap with encrypted fixed/floating rates
contract EncryptedInterestRateSwap is ZamaEthereumConfig, Ownable {
    struct Swap {
        address fixedPayer; address floatingPayer;
        euint64 notional; euint64 fixedRateBps;
        euint64 currentFloatingRateBps; uint256 maturity; uint256 lastSettlement; bool active;
    }
    mapping(uint256 => Swap) private swaps;
    uint256 public swapCount;
    mapping(address => euint64) private _netPayments;

    event SwapCreated(uint256 indexed id); event SettlementPaid(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function createSwap(address floatingPayer, externalEuint64 encNotional, bytes calldata nProof,
                        externalEuint64 encFixed, bytes calldata fProof, uint256 maturityYears)
        external returns (uint256 id) {
        euint64 notional = FHE.fromExternal(encNotional, nProof);
        euint64 fixedR = FHE.fromExternal(encFixed, fProof);
        id = swapCount++;
        swaps[id] = Swap({ fixedPayer: msg.sender, floatingPayer: floatingPayer, notional: notional,
            fixedRateBps: fixedR, currentFloatingRateBps: FHE.asEuint64(0),
            maturity: block.timestamp + maturityYears * 365 days, lastSettlement: block.timestamp, active: true });
        FHE.allowThis(swaps[id].notional); FHE.allowThis(swaps[id].fixedRateBps);
        FHE.allow(swaps[id].fixedRateBps, floatingPayer); // [acl_misconfig]
        FHE.allow(swaps[id].notional, msg.sender); // [acl_misconfig]
        FHE.allowThis(swaps[id].currentFloatingRateBps);
        emit SwapCreated(id);
    }

    function updateFloatingRate(uint256 swapId, externalEuint64 encRate, bytes calldata proof) external onlyOwner {
        euint64 rate = FHE.fromExternal(encRate, proof);
        swaps[swapId].currentFloatingRateBps = rate;
        FHE.allowThis(swaps[swapId].currentFloatingRateBps);
        FHE.allow(rate, swaps[swapId].fixedPayer);
        FHE.allow(rate, swaps[swapId].floatingPayer);
    }

    function settle(uint256 swapId) external {
        Swap storage s = swaps[swapId];
        require(s.active, "Inactive");
        uint256 elapsed = (block.timestamp - s.lastSettlement) / 365 days;
        if (elapsed == 0) return;
        s.lastSettlement = block.timestamp;
        euint64 fixedPayment = FHE.div(FHE.mul(s.notional, s.fixedRateBps), 10000);
        euint64 floatPayment = FHE.div(FHE.mul(s.notional, s.currentFloatingRateBps), 10000);
        // Net payment: if fixed > float, floatingPayer receives (fixed - float); else vice versa
        ebool fixedHigher = FHE.gt(fixedPayment, floatPayment);
        euint64 netAmount = FHE.select(fixedHigher, FHE.sub(fixedPayment, floatPayment), FHE.sub(floatPayment, fixedPayment));
        _netPayments[s.fixedPayer] = FHE.add(_netPayments[s.fixedPayer], FHE.select(fixedHigher, FHE.asEuint64(0), netAmount));
        _netPayments[s.floatingPayer] = FHE.add(_netPayments[s.floatingPayer], FHE.select(fixedHigher, netAmount, FHE.asEuint64(0)));
        FHE.allowThis(_netPayments[s.fixedPayer]); FHE.allow(_netPayments[s.fixedPayer], s.fixedPayer);
        FHE.allowThis(_netPayments[s.floatingPayer]); FHE.allow(_netPayments[s.floatingPayer], s.floatingPayer);
        if (block.timestamp >= s.maturity) s.active = false;
        emit SettlementPaid(swapId);
    }

    function allowSwapDetails(uint256 id, address viewer) external {
        Swap storage s = swaps[id];
        require(msg.sender == s.fixedPayer || msg.sender == s.floatingPayer || msg.sender == owner(), "Unauthorized");
        FHE.allow(s.notional, viewer); FHE.allow(s.fixedRateBps, viewer);
    }
}
