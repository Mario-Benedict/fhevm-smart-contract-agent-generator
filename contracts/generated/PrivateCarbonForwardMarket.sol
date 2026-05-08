// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCarbonForwardMarket
/// @notice OTC carbon forward contracts: encrypted forward price, encrypted volume commitment,
///         encrypted counterparty credit limit, encrypted margin deposits, and sealed settlement.
contract PrivateCarbonForwardMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    struct ForwardContract {
        address buyer;
        address seller;
        euint64 forwardPricePerTon;   // encrypted USD/ton
        euint64 volumeTons;            // encrypted metric tons committed
        euint64 buyerMarginDeposit;    // encrypted collateral posted by buyer
        euint64 sellerMarginDeposit;   // encrypted collateral posted by seller
        euint64 settlementAmount;      // encrypted final cash settlement
        uint256 maturityDate;
        bool settled;
        bool disputed;
    }

    struct CounterpartyProfile {
        euint64 creditLimit;          // encrypted max notional exposure
        euint64 currentExposure;      // encrypted current open exposure
        euint64 reputationScore;      // encrypted reputation (0-1000)
        bool approved;
    }

    mapping(uint256 => ForwardContract) private forwards;
    mapping(address => CounterpartyProfile) private profiles;
    mapping(address => bool) public isBroker;
    euint64 private _totalMarketExposure;
    uint256 public forwardCount;

    event ForwardCreated(uint256 indexed id, address buyer, address seller);
    event MarginPosted(uint256 indexed id, address poster);
    event ForwardSettled(uint256 indexed id);
    event DisputeRaised(uint256 indexed id);
    event CounterpartyApproved(address indexed cp);

    constructor() Ownable(msg.sender) {
        _totalMarketExposure = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketExposure);
        isBroker[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isBroker[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function approveCounterparty(
        address cp,
        externalEuint64 encLimit, bytes calldata lProof,
        externalEuint64 encScore, bytes calldata sProof
    ) external {
        require(isBroker[msg.sender], "Not broker");
        euint64 limit = FHE.fromExternal(encLimit, lProof);
        euint64 score = FHE.fromExternal(encScore, sProof);
        profiles[cp] = CounterpartyProfile({
            creditLimit: limit,
            currentExposure: FHE.asEuint64(0),
            reputationScore: score,
            approved: true
        });
        FHE.allowThis(profiles[cp].creditLimit);
        FHE.allowThis(profiles[cp].currentExposure);
        FHE.allowThis(profiles[cp].reputationScore);
        FHE.allow(profiles[cp].creditLimit, cp);
        FHE.allow(profiles[cp].reputationScore, cp);
        emit CounterpartyApproved(cp);
    }

    function createForward(
        address seller,
        externalEuint64 encPrice, bytes calldata priceProof,
        externalEuint64 encVolume, bytes calldata volProof,
        uint256 maturity
    ) external whenNotPaused returns (uint256 id) {
        require(profiles[msg.sender].approved && profiles[seller].approved, "Unapproved counterparty");
        euint64 price = FHE.fromExternal(encPrice, priceProof);
        euint64 volume = FHE.fromExternal(encVolume, volProof);
        euint64 notional = FHE.mul(price, volume);
        // Check buyer credit limit
        ebool withinLimit = FHE.le(
            FHE.add(profiles[msg.sender].currentExposure, notional),
            profiles[msg.sender].creditLimit
        );
        euint64 acceptedNotional = FHE.select(withinLimit, notional, FHE.asEuint64(0));
        id = forwardCount++;
        forwards[id] = ForwardContract({
            buyer: msg.sender, seller: seller,
            forwardPricePerTon: price, volumeTons: volume,
            buyerMarginDeposit: FHE.asEuint64(0),
            sellerMarginDeposit: FHE.asEuint64(0),
            settlementAmount: FHE.asEuint64(0),
            maturityDate: maturity,
            settled: false, disputed: false
        });
        profiles[msg.sender].currentExposure = FHE.add(profiles[msg.sender].currentExposure, acceptedNotional);
        _totalMarketExposure = FHE.add(_totalMarketExposure, acceptedNotional);
        FHE.allowThis(forwards[id].forwardPricePerTon);
        FHE.allowThis(forwards[id].volumeTons);
        FHE.allowThis(forwards[id].buyerMarginDeposit);
        FHE.allowThis(forwards[id].sellerMarginDeposit);
        FHE.allowThis(forwards[id].settlementAmount);
        FHE.allowThis(profiles[msg.sender].currentExposure);
        FHE.allowThis(_totalMarketExposure);
        emit ForwardCreated(id, msg.sender, seller);
    }

    function postMargin(uint256 fwdId, externalEuint64 encMargin, bytes calldata proof) external nonReentrant whenNotPaused {
        ForwardContract storage fwd = forwards[fwdId];
        require(!fwd.settled, "Already settled");
        euint64 margin = FHE.fromExternal(encMargin, proof);
        if (msg.sender == fwd.buyer) {
            fwd.buyerMarginDeposit = FHE.add(fwd.buyerMarginDeposit, margin);
            FHE.allowThis(fwd.buyerMarginDeposit);
            FHE.allow(fwd.buyerMarginDeposit, fwd.buyer);
        } else if (msg.sender == fwd.seller) {
            fwd.sellerMarginDeposit = FHE.add(fwd.sellerMarginDeposit, margin);
            FHE.allowThis(fwd.sellerMarginDeposit);
            FHE.allow(fwd.sellerMarginDeposit, fwd.seller);
        } else {
            revert("Not counterparty");
        }
        emit MarginPosted(fwdId, msg.sender);
    }

    function settle(uint256 fwdId, externalEuint64 encSpotPrice, bytes calldata proof) external nonReentrant {
        require(isBroker[msg.sender], "Not broker");
        ForwardContract storage fwd = forwards[fwdId];
        require(!fwd.settled && block.timestamp >= fwd.maturityDate, "Not ready");
        euint64 spotPrice = FHE.fromExternal(encSpotPrice, proof);
        // Settlement = (forward - spot) * volume (buyer profit if forward < spot)
        ebool buyerProfits = FHE.lt(fwd.forwardPricePerTon, spotPrice);
        euint64 diff = FHE.select(buyerProfits,
            FHE.sub(spotPrice, fwd.forwardPricePerTon),
            FHE.sub(fwd.forwardPricePerTon, spotPrice)
        );
        fwd.settlementAmount = FHE.mul(diff, fwd.volumeTons);
        fwd.settled = true;
        FHE.allowThis(fwd.settlementAmount);
        FHE.allow(fwd.settlementAmount, fwd.buyer);
        FHE.allow(fwd.settlementAmount, fwd.seller);
        emit ForwardSettled(fwdId);
    }

    function raiseDispute(uint256 fwdId) external {
        ForwardContract storage fwd = forwards[fwdId];
        require(msg.sender == fwd.buyer || msg.sender == fwd.seller, "Not counterparty");
        fwd.disputed = true;
        emit DisputeRaised(fwdId);
    }

    function allowBrokerView(uint256 fwdId, address broker) external {
        require(isBroker[msg.sender], "Not broker");
        FHE.allow(forwards[fwdId].forwardPricePerTon, broker);
        FHE.allow(forwards[fwdId].volumeTons, broker);
        FHE.allow(forwards[fwdId].settlementAmount, broker);
    }
}
