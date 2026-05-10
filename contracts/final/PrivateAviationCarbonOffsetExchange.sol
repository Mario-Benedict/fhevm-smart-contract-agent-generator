// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAviationCarbonOffsetExchange
/// @notice Airline carbon offset trading: encrypted flight emissions, hidden offset purchase prices,
///         confidential compliance deficits under CORSIA, and private negotiation of offset credits
///         between airlines and project developers.
contract PrivateAviationCarbonOffsetExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OffsetType { CORSIA_Eligible, VCM_Gold, VCM_VCS, Nature_Based, TechBased }

    struct AirlineEmissionRecord {
        address airline;
        string airlineCode;
        euint64 annualEmissionsTonnesCO2; // encrypted annual emissions
        euint64 baselineEmissionsTonnes;  // encrypted CORSIA baseline
        euint64 offsetObligationTonnes;   // encrypted offset obligation
        euint64 offsetsPurchasedTonnes;   // encrypted offsets already purchased
        euint64 complianceDeficitTonnes;  // encrypted remaining deficit
        uint32 complianceYear;
    }

    struct OffsetListing {
        address developer;
        OffsetType offsetType;
        string projectCode;
        euint32 availableVolumesTonnes;  // encrypted available volume
        euint64 askPricePerTonne;        // encrypted ask price
        euint64 corsiaEligibilityScore;  // encrypted eligibility score
        bool verified;
    }

    struct OffsetPurchase {
        uint256 listingId;
        uint256 emissionRecordId;
        address airline;
        euint32 purchasedTonnes;         // encrypted tonnes purchased
        euint64 totalCostUSD;            // encrypted total cost
        uint256 settledAt;
    }

    mapping(uint256 => AirlineEmissionRecord) private emissionRecords;
    mapping(uint256 => OffsetListing) private listings;
    mapping(uint256 => OffsetPurchase) private purchases;
    mapping(address => bool) public isICAOVerifier;

    uint256 public recordCount;
    uint256 public listingCount;
    uint256 public purchaseCount;
    euint64 private _totalOffsetsPurchasedTonnes;
    euint64 private _totalExchangeVolumeUSD;

    event EmissionRecordCreated(uint256 indexed id, string airlineCode, uint32 complianceYear);
    event OffsetListed(uint256 indexed id, OffsetType offsetType, string projectCode);
    event OffsetPurchaseSettled(uint256 indexed purchaseId);

    modifier onlyICAOVerifier() {
        require(isICAOVerifier[msg.sender] || msg.sender == owner(), "Not ICAO verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalOffsetsPurchasedTonnes = FHE.asEuint64(0);
        _totalExchangeVolumeUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalOffsetsPurchasedTonnes);
        FHE.allowThis(_totalExchangeVolumeUSD);
        isICAOVerifier[msg.sender] = true;
    }

    function addICAOVerifier(address v) external onlyOwner { isICAOVerifier[v] = true; }

    function registerEmissions(
        string calldata airlineCode,
        uint32 complianceYear,
        externalEuint64 encAnnual, bytes calldata aProof,
        externalEuint64 encBaseline, bytes calldata bProof
    ) external returns (uint256 id) {
        euint64 annual = FHE.fromExternal(encAnnual, aProof);
        euint64 baseline = FHE.fromExternal(encBaseline, bProof);
        // Obligation = max(annual - baseline, 0) via FHE select
        ebool exceedsBaseline = FHE.gt(annual, baseline);
        euint64 obligation = FHE.select(exceedsBaseline, FHE.sub(annual, baseline), FHE.asEuint64(0));
        id = recordCount++;
        emissionRecords[id] = AirlineEmissionRecord({
            airline: msg.sender, airlineCode: airlineCode,
            annualEmissionsTonnesCO2: annual, baselineEmissionsTonnes: baseline,
            offsetObligationTonnes: obligation, offsetsPurchasedTonnes: FHE.asEuint64(0),
            complianceDeficitTonnes: obligation, complianceYear: complianceYear
        });
        FHE.allowThis(emissionRecords[id].annualEmissionsTonnesCO2); FHE.allow(emissionRecords[id].annualEmissionsTonnesCO2, msg.sender);
        FHE.allowThis(emissionRecords[id].baselineEmissionsTonnes); FHE.allow(emissionRecords[id].baselineEmissionsTonnes, msg.sender);
        FHE.allowThis(emissionRecords[id].offsetObligationTonnes); FHE.allow(emissionRecords[id].offsetObligationTonnes, msg.sender);
        FHE.allowThis(emissionRecords[id].offsetsPurchasedTonnes); FHE.allow(emissionRecords[id].offsetsPurchasedTonnes, msg.sender);
        FHE.allowThis(emissionRecords[id].complianceDeficitTonnes); FHE.allow(emissionRecords[id].complianceDeficitTonnes, msg.sender);
        emit EmissionRecordCreated(id, airlineCode, complianceYear);
    }

    function listOffset(
        OffsetType offsetType,
        string calldata projectCode,
        externalEuint32 encVolume, bytes calldata vProof,
        externalEuint64 encAskPrice, bytes calldata apProof,
        externalEuint64 encEligScore, bytes calldata esProof
    ) external returns (uint256 id) {
        euint32 vol = FHE.fromExternal(encVolume, vProof);
        euint64 askPrice = FHE.fromExternal(encAskPrice, apProof);
        euint64 eligScore = FHE.fromExternal(encEligScore, esProof);
        id = listingCount++;
        listings[id] = OffsetListing({
            developer: msg.sender, offsetType: offsetType, projectCode: projectCode,
            availableVolumesTonnes: vol, askPricePerTonne: askPrice,
            corsiaEligibilityScore: eligScore, verified: false
        });
        FHE.allowThis(listings[id].availableVolumesTonnes); FHE.allow(listings[id].availableVolumesTonnes, msg.sender);
        FHE.allowThis(listings[id].askPricePerTonne); FHE.allow(listings[id].askPricePerTonne, msg.sender);
        FHE.allowThis(listings[id].corsiaEligibilityScore);
        emit OffsetListed(id, offsetType, projectCode);
    }

    function verifyListing(uint256 listingId) external onlyICAOVerifier {
        listings[listingId].verified = true;
        FHE.allow(listings[listingId].corsiaEligibilityScore, msg.sender);
    }

    function purchaseOffset(
        uint256 listingId,
        uint256 emissionRecordId,
        externalEuint32 encTonnes, bytes calldata tProof
    ) external nonReentrant returns (uint256 purchaseId) {
        OffsetListing storage l = listings[listingId];
        require(l.verified, "Listing not verified");
        AirlineEmissionRecord storage rec = emissionRecords[emissionRecordId];
        require(msg.sender == rec.airline, "Not airline");
        euint32 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 totalCost = FHE.mul(FHE.asEuint64(uint64(1)), l.askPricePerTonne); // proxy calc
        purchaseId = purchaseCount++;
        purchases[purchaseId] = OffsetPurchase({
            listingId: listingId, emissionRecordId: emissionRecordId, airline: msg.sender,
            purchasedTonnes: tonnes, totalCostUSD: totalCost, settledAt: block.timestamp
        });
        rec.offsetsPurchasedTonnes = FHE.add(rec.offsetsPurchasedTonnes, FHE.asEuint64(uint64(1)));
        l.availableVolumesTonnes = FHE.sub(l.availableVolumesTonnes, tonnes);
        _totalOffsetsPurchasedTonnes = FHE.add(_totalOffsetsPurchasedTonnes, FHE.asEuint64(uint64(1)));
        _totalExchangeVolumeUSD = FHE.add(_totalExchangeVolumeUSD, totalCost);
        FHE.allowThis(purchases[purchaseId].purchasedTonnes); FHE.allow(purchases[purchaseId].purchasedTonnes, msg.sender); FHE.allow(purchases[purchaseId].purchasedTonnes, l.developer);
        FHE.allowThis(purchases[purchaseId].totalCostUSD); FHE.allow(purchases[purchaseId].totalCostUSD, msg.sender); FHE.allow(purchases[purchaseId].totalCostUSD, l.developer);
        FHE.allowThis(rec.offsetsPurchasedTonnes); FHE.allow(rec.offsetsPurchasedTonnes, msg.sender);
        FHE.allowThis(l.availableVolumesTonnes); FHE.allow(l.availableVolumesTonnes, l.developer);
        FHE.allowThis(_totalOffsetsPurchasedTonnes);
        FHE.allowThis(_totalExchangeVolumeUSD);
        emit OffsetPurchaseSettled(purchaseId);
    }

    function allowExchangeStats(address viewer) external onlyOwner {
        FHE.allow(_totalOffsetsPurchasedTonnes, viewer);
        FHE.allow(_totalExchangeVolumeUSD, viewer);
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