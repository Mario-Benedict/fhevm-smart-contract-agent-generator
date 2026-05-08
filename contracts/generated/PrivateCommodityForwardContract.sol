// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateCommodityForwardContract
/// @notice OTC commodity forward: two counterparties agree on encrypted forward price and quantity.
///         Settlement computed privately when delivery date arrives with oracle spot price.
contract PrivateCommodityForwardContract is ZamaEthereumConfig, Ownable {
    enum CommodityType { Crude, Gold, Wheat, NatGas, Copper }
    enum SettlementStatus { Pending, OracleReported, Settled, Defaulted }

    struct Forward {
        address buyer;
        address seller;
        CommodityType commodity;
        euint64 forwardPrice;    // encrypted agreed forward price per unit
        euint64 quantity;        // encrypted quantity in units
        euint64 margin;          // encrypted margin deposited by each party
        euint64 spotPrice;       // encrypted oracle spot at settlement
        euint64 settlementPnL;   // encrypted buyer P&L (can be negative)
        uint256 deliveryDate;
        SettlementStatus status;
    }

    mapping(uint256 => Forward) private forwards;
    mapping(address => euint64) private _partyBalance;
    uint256 public forwardCount;
    address public commodityOracle;
    mapping(address => bool) public isCounterparty;
    euint64 private _totalOpenInterest;

    event ForwardCreated(uint256 indexed id, CommodityType commodity);
    event MarginDeposited(uint256 indexed id, address party);
    event SpotPriceReported(uint256 indexed id);
    event ForwardSettled(uint256 indexed id);
    event ForwardDefaulted(uint256 indexed id, address defaulter);

    modifier onlyOracle() {
        require(msg.sender == commodityOracle || msg.sender == owner(), "Not oracle");
        _;
    }

    constructor(address oracle) Ownable(msg.sender) {
        commodityOracle = oracle;
        _totalOpenInterest = FHE.asEuint64(0);
        FHE.allowThis(_totalOpenInterest);
    }

    function addCounterparty(address cp) external onlyOwner { isCounterparty[cp] = true; }

    function createForward(
        address seller, CommodityType commodity,
        externalEuint64 encForwardPrice, bytes calldata fpProof,
        externalEuint64 encQuantity, bytes calldata qProof,
        externalEuint64 encMargin, bytes calldata mProof,
        uint256 deliveryDays
    ) external returns (uint256 id) {
        require(isCounterparty[msg.sender], "Not counterparty");
        euint64 fwdPrice = FHE.fromExternal(encForwardPrice, fpProof);
        euint64 qty = FHE.fromExternal(encQuantity, qProof);
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        id = forwardCount++;
        forwards[id] = Forward({
            buyer: msg.sender, seller: seller, commodity: commodity,
            forwardPrice: fwdPrice, quantity: qty, margin: margin,
            spotPrice: FHE.asEuint64(0), settlementPnL: FHE.asEuint64(0),
            deliveryDate: block.timestamp + deliveryDays * 1 days,
            status: SettlementStatus.Pending
        });
        _totalOpenInterest = FHE.add(_totalOpenInterest, FHE.mul(fwdPrice, qty));
        FHE.allowThis(forwards[id].forwardPrice);
        FHE.allow(forwards[id].forwardPrice, msg.sender);
        FHE.allow(forwards[id].forwardPrice, seller);
        FHE.allowThis(forwards[id].quantity);
        FHE.allowThis(forwards[id].margin);
        FHE.allow(forwards[id].margin, msg.sender);
        FHE.allowThis(forwards[id].spotPrice);
        FHE.allowThis(forwards[id].settlementPnL);
        FHE.allowThis(_totalOpenInterest);
        if (!FHE.isInitialized(_partyBalance[msg.sender])) {
            _partyBalance[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_partyBalance[msg.sender]);
        }
        if (!FHE.isInitialized(_partyBalance[seller])) {
            _partyBalance[seller] = FHE.asEuint64(0);
            FHE.allowThis(_partyBalance[seller]);
        }
        emit ForwardCreated(id, commodity);
    }

    function depositMargin(uint256 fwdId, externalEuint64 encMargin, bytes calldata proof) external {
        Forward storage f = forwards[fwdId];
        require(msg.sender == f.buyer || msg.sender == f.seller, "Not party");
        euint64 margin = FHE.fromExternal(encMargin, proof);
        _partyBalance[msg.sender] = FHE.add(_partyBalance[msg.sender], margin);
        FHE.allowThis(_partyBalance[msg.sender]);
        FHE.allow(_partyBalance[msg.sender], msg.sender);
        emit MarginDeposited(fwdId, msg.sender);
    }

    function reportSpotPrice(uint256 fwdId, externalEuint64 encSpot, bytes calldata proof) external onlyOracle {
        euint64 spot = FHE.fromExternal(encSpot, proof);
        forwards[fwdId].spotPrice = spot;
        forwards[fwdId].status = SettlementStatus.OracleReported;
        FHE.allowThis(forwards[fwdId].spotPrice);
        FHE.allow(forwards[fwdId].spotPrice, forwards[fwdId].buyer);
        FHE.allow(forwards[fwdId].spotPrice, forwards[fwdId].seller);
        emit SpotPriceReported(fwdId);
    }

    function settleForward(uint256 fwdId) external {
        Forward storage f = forwards[fwdId];
        require(f.status == SettlementStatus.OracleReported, "Not ready");
        require(block.timestamp >= f.deliveryDate, "Not delivery date");
        // P&L for buyer = (spot - forward) * quantity
        ebool spotHigher = FHE.gt(f.spotPrice, f.forwardPrice);
        euint64 priceDiff = FHE.select(spotHigher,
            FHE.sub(f.spotPrice, f.forwardPrice),
            FHE.sub(f.forwardPrice, f.spotPrice));
        euint64 pnl = FHE.mul(priceDiff, f.quantity);
        f.settlementPnL = pnl;
        _totalOpenInterest = FHE.sub(_totalOpenInterest, FHE.mul(f.forwardPrice, f.quantity));
        f.status = SettlementStatus.Settled;
        FHE.allowThis(f.settlementPnL);
        FHE.allow(f.settlementPnL, f.buyer);
        FHE.allow(f.settlementPnL, f.seller);
        FHE.allowThis(_totalOpenInterest);
        if (FHE.isInitialized(spotHigher)) {
            // Buyer profits
            _partyBalance[f.buyer] = FHE.add(_partyBalance[f.buyer], pnl);
            _partyBalance[f.seller] = FHE.sub(_partyBalance[f.seller], pnl);
        } else {
            _partyBalance[f.seller] = FHE.add(_partyBalance[f.seller], pnl);
            _partyBalance[f.buyer] = FHE.sub(_partyBalance[f.buyer], pnl);
        }
        FHE.allowThis(_partyBalance[f.buyer]);
        FHE.allow(_partyBalance[f.buyer], f.buyer);
        FHE.allowThis(_partyBalance[f.seller]);
        FHE.allow(_partyBalance[f.seller], f.seller);
        emit ForwardSettled(fwdId);
    }

    function allowForwardDetails(uint256 fwdId, address viewer) external {
        Forward storage f = forwards[fwdId];
        require(msg.sender == f.buyer || msg.sender == f.seller || msg.sender == owner(), "Unauthorized");
        FHE.allow(f.forwardPrice, viewer);
        FHE.allow(f.quantity, viewer);
        FHE.allow(f.settlementPnL, viewer);
    }
}
