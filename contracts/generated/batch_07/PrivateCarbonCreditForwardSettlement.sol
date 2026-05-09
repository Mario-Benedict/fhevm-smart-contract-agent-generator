// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateCarbonCreditForwardSettlement
/// @notice Bilateral OTC forward contracts for carbon credits with encrypted
///         strike prices, volumes, and settlement amounts. Supports physical
///         and cash delivery, credit risk netting, and margining.
contract PrivateCarbonCreditForwardSettlement is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum DeliveryMode { PHYSICAL, CASH_SETTLED }
    enum ContractStatus { PENDING, ACTIVE, SETTLED, DEFAULTED, TERMINATED }
    enum CreditStandard { VCS, GOLD_STANDARD, ACR, CAR, CDM }

    struct ForwardContract {
        address buyer;
        address seller;
        CreditStandard standard;
        DeliveryMode delivery;
        ContractStatus status;
        euint64 strikePrice;        // encrypted USD per tonne CO2e
        euint64 volume;             // encrypted tonnes to deliver
        euint64 totalNotional;      // encrypted total contract value
        euint64 buyerMargin;        // encrypted buyer initial margin
        euint64 sellerMargin;       // encrypted seller initial margin
        euint64 settlementPrice;    // encrypted final market price at maturity
        euint64 settlementAmount;   // encrypted cash settlement amount
        uint256 maturityDate;
        bool buyerDefaulted;
        bool sellerDefaulted;
    }

    struct CounterpartyExposure {
        euint64 totalLongNotional;   // encrypted aggregate long position
        euint64 totalShortNotional;  // encrypted aggregate short position
        euint64 netExposure;         // encrypted net exposure
        euint64 postedMargin;        // encrypted total margin posted
        uint256 activeContracts;
    }

    mapping(bytes32 => ForwardContract) private forwards;
    mapping(address => CounterpartyExposure) private exposures;
    mapping(address => bool) public approvedCounterparty;
    mapping(bytes32 => bool) public contractExists;

    euint64 private _initialMarginRateBps;   // encrypted margin rate
    euint64 private _variationMarginBuffer;  // encrypted VM buffer
    euint64 private _totalOpenInterest;      // encrypted OI
    euint64 private _defaultFundBalance;     // encrypted default fund

    event ForwardCreated(bytes32 indexed contractId, address buyer, address seller, uint256 maturityDate);
    event ForwardSettled(bytes32 indexed contractId);
    event MarginCalled(address indexed counterparty);
    event DefaultDeclared(bytes32 indexed contractId, address defaulter);

    constructor(
        externalEuint64 encInitialMarginRate, bytes memory imrProof,
        externalEuint64 encVMBuffer, bytes memory vmProof
    ) Ownable(msg.sender) {
        _initialMarginRateBps = FHE.fromExternal(encInitialMarginRate, imrProof);
        _variationMarginBuffer = FHE.fromExternal(encVMBuffer, vmProof);
        _totalOpenInterest = FHE.asEuint64(0);
        _defaultFundBalance = FHE.asEuint64(0);
        FHE.allowThis(_initialMarginRateBps);
        FHE.allowThis(_variationMarginBuffer);
        FHE.allowThis(_totalOpenInterest);
        FHE.allowThis(_defaultFundBalance);
    }

    modifier onlyApproved() {
        require(approvedCounterparty[msg.sender], "Not approved counterparty");
        _;
    }

    function approveCounterparty(address cp) external onlyOwner {
        approvedCounterparty[cp] = true;
    }

    function createForward(
        address counterparty,
        bool isBuyer,
        CreditStandard standard,
        DeliveryMode delivery,
        externalEuint64 encStrikePrice, bytes calldata spProof,
        externalEuint64 encVolume, bytes calldata volProof,
        uint256 maturityDate
    ) external onlyApproved nonReentrant returns (bytes32 contractId) {
        require(approvedCounterparty[counterparty], "Counterparty not approved");
        require(maturityDate > block.timestamp, "Invalid maturity");

        euint64 strikePrice = FHE.fromExternal(encStrikePrice, spProof);
        euint64 volume = FHE.fromExternal(encVolume, volProof);
        euint64 totalNotional = FHE.mul(strikePrice, volume);
        euint64 margin = FHE.div(FHE.mul(totalNotional, _initialMarginRateBps), 10000);

        address buyer = isBuyer ? msg.sender : counterparty;
        address seller = isBuyer ? counterparty : msg.sender;

        contractId = keccak256(abi.encodePacked(buyer, seller, block.timestamp, maturityDate));
        require(!contractExists[contractId], "Duplicate contract");
        contractExists[contractId] = true;

        ForwardContract storage _s0 = forwards[contractId];
        _s0.buyer = buyer;
        _s0.seller = seller;
        _s0.standard = standard;
        _s0.delivery = delivery;
        _s0.status = ContractStatus.ACTIVE;
        _s0.strikePrice = strikePrice;
        _s0.volume = volume;
        _s0.totalNotional = totalNotional;
        _s0.buyerMargin = margin;
        _s0.sellerMargin = margin;
        _s0.settlementPrice = FHE.asEuint64(0);
        _s0.settlementAmount = FHE.asEuint64(0);
        _s0.maturityDate = maturityDate;
        _s0.buyerDefaulted = false;
        _s0.sellerDefaulted = false;

        FHE.allowThis(strikePrice);
        FHE.allowThis(volume);
        FHE.allowThis(totalNotional);
        FHE.allowThis(margin);
        FHE.allow(margin, buyer);
        FHE.allow(margin, seller);

        _totalOpenInterest = FHE.add(_totalOpenInterest, totalNotional);
        FHE.allowThis(_totalOpenInterest);

        CounterpartyExposure storage buyerExp = exposures[buyer];
        buyerExp.totalLongNotional = FHE.add(buyerExp.totalLongNotional, totalNotional);
        buyerExp.postedMargin = FHE.add(buyerExp.postedMargin, margin);
        buyerExp.activeContracts++;
        FHE.allowThis(buyerExp.totalLongNotional);
        FHE.allow(buyerExp.totalLongNotional, buyer);
        FHE.allowThis(buyerExp.postedMargin);
        FHE.allow(buyerExp.postedMargin, buyer);

        CounterpartyExposure storage sellerExp = exposures[seller];
        sellerExp.totalShortNotional = FHE.add(sellerExp.totalShortNotional, totalNotional);
        sellerExp.postedMargin = FHE.add(sellerExp.postedMargin, margin);
        sellerExp.activeContracts++;
        FHE.allowThis(sellerExp.totalShortNotional);
        FHE.allow(sellerExp.totalShortNotional, seller);
        FHE.allowThis(sellerExp.postedMargin);
        FHE.allow(sellerExp.postedMargin, seller);

        emit ForwardCreated(contractId, buyer, seller, maturityDate);
    }

    function settleForward(
        bytes32 contractId,
        externalEuint64 encSettlementPrice, bytes calldata settlProof
    ) external onlyOwner {
        ForwardContract storage fwd = forwards[contractId];
        require(fwd.status == ContractStatus.ACTIVE, "Not active");
        require(block.timestamp >= fwd.maturityDate, "Not matured");

        euint64 settlementPrice = FHE.fromExternal(encSettlementPrice, settlProof);
        fwd.settlementPrice = settlementPrice;

        ebool priceUp = FHE.gt(settlementPrice, fwd.strikePrice);
        euint64 priceDiff = FHE.select(priceUp,
            FHE.sub(settlementPrice, fwd.strikePrice),
            FHE.sub(fwd.strikePrice, settlementPrice));
        euint64 settlementAmount = FHE.mul(priceDiff, fwd.volume);
        fwd.settlementAmount = settlementAmount;
        fwd.status = ContractStatus.SETTLED;

        _totalOpenInterest = FHE.sub(_totalOpenInterest, fwd.totalNotional);
        FHE.allowThis(_totalOpenInterest);
        FHE.allowThis(fwd.settlementPrice);
        FHE.allow(fwd.settlementPrice, fwd.buyer);
        FHE.allow(fwd.settlementPrice, fwd.seller);
        FHE.allowThis(fwd.settlementAmount);
        FHE.allow(fwd.settlementAmount, fwd.buyer);
        FHE.allow(fwd.settlementAmount, fwd.seller);

        emit ForwardSettled(contractId);
    }

    function declareDefault(bytes32 contractId, bool isBuyerDefault) external onlyOwner {
        ForwardContract storage fwd = forwards[contractId];
        require(fwd.status == ContractStatus.ACTIVE, "Not active");
        if (isBuyerDefault) {
            fwd.buyerDefaulted = true;
            _defaultFundBalance = FHE.add(_defaultFundBalance, fwd.buyerMargin);
            emit DefaultDeclared(contractId, fwd.buyer);
        } else {
            fwd.sellerDefaulted = true;
            _defaultFundBalance = FHE.add(_defaultFundBalance, fwd.sellerMargin);
            emit DefaultDeclared(contractId, fwd.seller);
        }
        fwd.status = ContractStatus.DEFAULTED;
        FHE.allowThis(_defaultFundBalance);
    }

    function allowExposureView(address cp) external {
        require(msg.sender == cp || msg.sender == owner(), "Unauthorized");
        CounterpartyExposure storage exp = exposures[cp];
        FHE.allow(exp.totalLongNotional, cp);
        FHE.allow(exp.totalShortNotional, cp);
        FHE.allow(exp.netExposure, cp);
        FHE.allow(exp.postedMargin, cp);
    }
}
