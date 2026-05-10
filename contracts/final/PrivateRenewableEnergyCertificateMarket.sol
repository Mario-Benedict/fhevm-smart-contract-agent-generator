// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRenewableEnergyCertificateMarket
/// @notice REC marketplace where production volumes, buyer identities, and
///         purchase prices remain encrypted. Enables corporates to make
///         confidential clean energy procurement commitments.
contract PrivateRenewableEnergyCertificateMarket is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EnergySource { SOLAR_PV, ONSHORE_WIND, OFFSHORE_WIND, HYDRO, GEOTHERMAL, BIOMASS, TIDAL }
    enum CertificateGrade { GOLD, SILVER, STANDARD, ADDITIONALITY_VERIFIED }

    struct RECIssuance {
        uint256 certId;
        address producer;
        EnergySource source;
        CertificateGrade grade;
        string facilityName;
        string country;
        euint64 mwhProduced;          // encrypted MWh generated
        euint64 certificatesIssued;   // encrypted number of RECs
        euint64 pricePerRECUSD;       // encrypted asking price
        euint64 carbonAvoidedTonnes;  // encrypted CO2 equivalent avoided
        uint256 generationYear;
        uint256 expiryDate;
        bool retired;
        bool listed;
    }

    struct BuyerPortfolio {
        euint64 totalRECsOwned;       // encrypted current holdings
        euint64 totalRECsRetired;     // encrypted RECs retired for sustainability claims
        euint64 totalSpendUSD;        // encrypted total procurement spend
        euint64 renewablePercentage;  // encrypted % of energy needs met by RECs
        euint32 annualTargetMWh;      // encrypted annual green energy target
        bool registered;
    }

    struct PurchaseOrder {
        address buyer;
        uint256 certId;
        euint64 quantityRECs;         // encrypted quantity purchased
        euint64 totalPriceUSD;        // encrypted total cost
        bool executed;
    }

    mapping(uint256 => RECIssuance) private certificates;
    mapping(address => BuyerPortfolio) private buyers;
    mapping(uint256 => PurchaseOrder) private orders;
    mapping(address => bool) public isVerifiedProducer;
    mapping(address => bool) public isRECVerifier;
    uint256 public certCount;
    uint256 public orderCount;
    euint64 private _totalMWhOnMarket;
    euint64 private _totalCarbonAvoided;
    euint64 private _marketTurnoverUSD;

    event CertificateIssued(uint256 indexed certId, address producer, EnergySource source);
    event CertificateListed(uint256 indexed certId);
    event RECsPurchased(uint256 indexed orderId, address buyer, uint256 certId);
    event RECsRetired(uint256 indexed certId, address buyer);
    event ProducerVerified(address indexed producer);

    constructor() Ownable(msg.sender) {
        _totalMWhOnMarket = FHE.asEuint64(0);
        _totalCarbonAvoided = FHE.asEuint64(0);
        _marketTurnoverUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalMWhOnMarket);
        FHE.allowThis(_totalCarbonAvoided);
        FHE.allowThis(_marketTurnoverUSD);
        isRECVerifier[msg.sender] = true;
    }

    function verifyProducer(address producer) external {
        require(isRECVerifier[msg.sender], "Not verifier");
        isVerifiedProducer[producer] = true;
        emit ProducerVerified(producer);
    }

    function addVerifier(address v) external onlyOwner { isRECVerifier[v] = true; }

    function issueCertificate(
        EnergySource source,
        CertificateGrade grade,
        string calldata facilityName,
        string calldata country,
        externalEuint64 encMWh,    bytes calldata mwhProof,
        externalEuint64 encCO2,    bytes calldata co2Proof,
        externalEuint64 encPrice,  bytes calldata priceProof,
        uint256 genYear
    ) external returns (uint256 certId) {
        require(isVerifiedProducer[msg.sender], "Not verified producer");
        euint64 mwh   = FHE.fromExternal(encMWh, mwhProof);
        euint64 co2   = FHE.fromExternal(encCO2, co2Proof);
        euint64 price = FHE.fromExternal(encPrice, priceProof);
        certId = certCount++;
        RECIssuance storage _s0 = certificates[certId];
        _s0.certId = certId;
        _s0.producer = msg.sender;
        _s0.source = source;
        _s0.grade = grade;
        _s0.facilityName = facilityName;
        _s0.country = country;
        _s0.mwhProduced = mwh;
        _s0.certificatesIssued = mwh;
        _s0.// 1 REC = 1 MWh
            pricePerRECUSD = price;
        _s0.carbonAvoidedTonnes = co2;
        _s0.generationYear = genYear;
        _s0.expiryDate = block.timestamp + 3 * 365 days;
        _s0.retired = false;
        _s0.listed = false;
        _totalCarbonAvoided = FHE.add(_totalCarbonAvoided, co2);
        FHE.allowThis(certificates[certId].mwhProduced);
        FHE.allow(certificates[certId].mwhProduced, msg.sender); // [acl_misconfig]
        FHE.allow(_totalMWhOnMarket, msg.sender); // [acl_misconfig]
        FHE.allow(_totalCarbonAvoided, msg.sender); // [acl_misconfig]
        FHE.allowThis(certificates[certId].certificatesIssued);
        FHE.allow(certificates[certId].certificatesIssued, msg.sender);
        FHE.allowThis(certificates[certId].pricePerRECUSD);
        FHE.allow(certificates[certId].pricePerRECUSD, msg.sender);
        FHE.allowThis(certificates[certId].carbonAvoidedTonnes);
        FHE.allowThis(_totalCarbonAvoided);
        emit CertificateIssued(certId, msg.sender, source);
    }

    function listCertificate(uint256 certId) external {
        require(certificates[certId].producer == msg.sender, "Not producer");
        certificates[certId].listed = true;
        _totalMWhOnMarket = FHE.add(_totalMWhOnMarket, certificates[certId].mwhProduced);
        FHE.allowThis(_totalMWhOnMarket);
        emit CertificateListed(certId);
    }

    function registerBuyer(externalEuint32 encAnnualTarget, bytes calldata proof) external {
        euint32 target = FHE.fromExternal(encAnnualTarget, proof);
        buyers[msg.sender] = BuyerPortfolio({
            totalRECsOwned: FHE.asEuint64(0),
            totalRECsRetired: FHE.asEuint64(0),
            totalSpendUSD: FHE.asEuint64(0),
            renewablePercentage: FHE.asEuint64(0),
            annualTargetMWh: target,
            registered: true
        });
        FHE.allowThis(buyers[msg.sender].totalRECsOwned);
        FHE.allow(buyers[msg.sender].totalRECsOwned, msg.sender);
        FHE.allowThis(buyers[msg.sender].totalRECsRetired);
        FHE.allow(buyers[msg.sender].totalRECsRetired, msg.sender);
        FHE.allowThis(buyers[msg.sender].totalSpendUSD);
        FHE.allow(buyers[msg.sender].totalSpendUSD, msg.sender);
        FHE.allowThis(buyers[msg.sender].renewablePercentage);
        FHE.allow(buyers[msg.sender].renewablePercentage, msg.sender);
        FHE.allowThis(buyers[msg.sender].annualTargetMWh);
        FHE.allow(buyers[msg.sender].annualTargetMWh, msg.sender);
    }

    function purchaseRECs(
        uint256 certId,
        externalEuint64 encQuantity, bytes calldata proof
    ) external nonReentrant returns (uint256 orderId) {
        require(certificates[certId].listed && !certificates[certId].retired, "Not available");
        require(buyers[msg.sender].registered, "Buyer not registered");
        euint64 qty = FHE.fromExternal(encQuantity, proof);
        ebool available = FHE.le(qty, certificates[certId].certificatesIssued);
        euint64 actualQty = FHE.select(available, qty, certificates[certId].certificatesIssued);
        euint64 cost = FHE.mul(actualQty, certificates[certId].pricePerRECUSD);
        orderId = orderCount++;
        orders[orderId] = PurchaseOrder({
            buyer: msg.sender,
            certId: certId,
            quantityRECs: actualQty,
            totalPriceUSD: cost,
            executed: true
        });
        certificates[certId].certificatesIssued = FHE.sub(certificates[certId].certificatesIssued, actualQty);
        buyers[msg.sender].totalRECsOwned = FHE.add(buyers[msg.sender].totalRECsOwned, actualQty);
        buyers[msg.sender].totalSpendUSD = FHE.add(buyers[msg.sender].totalSpendUSD, cost);
        _marketTurnoverUSD = FHE.add(_marketTurnoverUSD, cost);
        FHE.allowThis(orders[orderId].quantityRECs);
        FHE.allow(orders[orderId].quantityRECs, msg.sender);
        FHE.allowThis(orders[orderId].totalPriceUSD);
        FHE.allow(orders[orderId].totalPriceUSD, msg.sender);
        FHE.allowThis(certificates[certId].certificatesIssued);
        FHE.allowThis(buyers[msg.sender].totalRECsOwned);
        FHE.allowThis(buyers[msg.sender].totalSpendUSD);
        FHE.allowThis(_marketTurnoverUSD);
        emit RECsPurchased(orderId, msg.sender, certId);
    }

    function retireRECs(uint256 certId, externalEuint64 encQty, bytes calldata proof) external {
        euint64 qty = FHE.fromExternal(encQty, proof);
        ebool hasEnough = FHE.ge(buyers[msg.sender].totalRECsOwned, qty);
        euint64 retireQty = FHE.select(hasEnough, qty, buyers[msg.sender].totalRECsOwned);
        buyers[msg.sender].totalRECsOwned = FHE.sub(buyers[msg.sender].totalRECsOwned, retireQty);
        buyers[msg.sender].totalRECsRetired = FHE.add(buyers[msg.sender].totalRECsRetired, retireQty);
        FHE.allowThis(buyers[msg.sender].totalRECsOwned);
        FHE.allowThis(buyers[msg.sender].totalRECsRetired);
        emit RECsRetired(certId, msg.sender);
    }

    function allowMarketView(address viewer) external onlyOwner {
        FHE.allow(_totalMWhOnMarket, viewer);
        FHE.allow(_totalCarbonAvoided, viewer);
        FHE.allow(_marketTurnoverUSD, viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}