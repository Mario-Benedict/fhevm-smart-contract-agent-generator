// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAquacultureSalmonFarmBond
/// @notice Encrypted salmon aquaculture farm bond: hidden biomass valuations, confidential
///         sea lice infestation risk scores, private mortality rate tracking, and encrypted
///         fish weight gain KPIs linked to bond coupon adjustments.
contract PrivateAquacultureSalmonFarmBond is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum SalmonSpecies { AtlanticSalmon, PacificCoho, Chinook, Steelhead, ArcticChar }
    enum ProductionPhase { Freshwater, Smolt, SeaPhase, HarvestReady }

    struct SalmonFarmBond {
        address farmOperator;
        SalmonSpecies species;
        string farmLocationRef;
        euint64 bondFaceValueUSD;      // encrypted bond face value
        euint64 biomassValueUSD;       // encrypted current biomass
        euint32 fishCountThousands;    // encrypted fish count (thousands)
        euint32 avgWeightGrams;        // encrypted average weight
        euint16 seaLiceInfestBps;      // encrypted sea lice risk score
        euint16 mortalityRateBps;      // encrypted mortality rate
        euint16 feedConversionRatioBps;// encrypted FCR
        euint16 couponRateBps;         // encrypted bond coupon
        ProductionPhase phase;
        uint256 bondMaturity;
    }

    struct BondInvestment {
        uint256 bondId;
        address investor;
        euint64 investedAmountUSD;     // encrypted investment
        euint64 couponEarnedUSD;       // encrypted coupon accrued
        uint256 investedAt;
    }

    mapping(uint256 => SalmonFarmBond) private bonds;
    mapping(uint256 => BondInvestment) private investments;
    mapping(address => bool) public isAquacultureAuthority;

    uint256 public bondCount;
    uint256 public investmentCount;
    euint64 private _totalBondCapitalUSD;

    event FarmBondIssued(uint256 indexed id, SalmonSpecies species);
    event BiomassUpdated(uint256 indexed bondId, uint256 updatedAt);
    event InvestorSubbed(uint256 indexed investId, uint256 bondId);

    modifier onlyAquacultureAuthority() {
        require(isAquacultureAuthority[msg.sender] || msg.sender == owner(), "Not authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBondCapitalUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalBondCapitalUSD);
        isAquacultureAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isAquacultureAuthority[a] = true; }

    function issueFarmBond(
        SalmonSpecies species, string calldata farmLocationRef,
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint64 encBiomass, bytes calldata bmProof,
        externalEuint32 encFishCount, bytes calldata fcProof,
        externalEuint16 encSeaLice, bytes calldata slProof,
        externalEuint16 encMortality, bytes calldata mrProof,
        externalEuint16 encCoupon, bytes calldata cProof,
        uint256 maturityDays
    ) external returns (uint256 id) {
        euint64 faceValue = FHE.fromExternal(encFaceValue, fvProof);
        euint64 biomass = FHE.fromExternal(encBiomass, bmProof);
        euint32 fishCount = FHE.fromExternal(encFishCount, fcProof);
        euint16 seaLice = FHE.fromExternal(encSeaLice, slProof);
        euint16 mortality = FHE.fromExternal(encMortality, mrProof);
        euint16 coupon = FHE.fromExternal(encCoupon, cProof);
        id = bondCount++;
        bonds[id] = SalmonFarmBond({
            farmOperator: msg.sender, species: species, farmLocationRef: farmLocationRef,
            bondFaceValueUSD: faceValue, biomassValueUSD: biomass, fishCountThousands: fishCount,
            avgWeightGrams: FHE.asEuint32(0), seaLiceInfestBps: seaLice, mortalityRateBps: mortality,
            feedConversionRatioBps: FHE.asEuint16(0), couponRateBps: coupon,
            phase: ProductionPhase.SeaPhase, bondMaturity: block.timestamp + maturityDays * 1 days
        });
        _totalBondCapitalUSD = FHE.add(_totalBondCapitalUSD, faceValue);
        FHE.allowThis(bonds[id].bondFaceValueUSD); FHE.allow(bonds[id].bondFaceValueUSD, msg.sender);
        FHE.allowThis(bonds[id].biomassValueUSD); FHE.allow(bonds[id].biomassValueUSD, msg.sender);
        FHE.allowThis(bonds[id].fishCountThousands); FHE.allow(bonds[id].fishCountThousands, msg.sender);
        FHE.allowThis(bonds[id].seaLiceInfestBps);
        FHE.allowThis(bonds[id].mortalityRateBps);
        FHE.allowThis(bonds[id].couponRateBps);
        FHE.allowThis(_totalBondCapitalUSD);
        emit FarmBondIssued(id, species);
    }

    function updateBiomassMetrics(
        uint256 bondId,
        externalEuint64 encBiomass, bytes calldata bmProof,
        externalEuint32 encAvgWeight, bytes calldata awProof,
        externalEuint16 encFCR, bytes calldata fcrProof
    ) external onlyAquacultureAuthority {
        SalmonFarmBond storage b = bonds[bondId];
        b.biomassValueUSD = FHE.fromExternal(encBiomass, bmProof);
        b.avgWeightGrams = FHE.fromExternal(encAvgWeight, awProof);
        b.feedConversionRatioBps = FHE.fromExternal(encFCR, fcrProof);
        FHE.allowThis(b.biomassValueUSD); FHE.allow(b.biomassValueUSD, b.farmOperator);
        FHE.allowThis(b.avgWeightGrams); FHE.allow(b.avgWeightGrams, b.farmOperator);
        FHE.allowThis(b.feedConversionRatioBps);
        emit BiomassUpdated(bondId, block.timestamp);
    }

    function investInBond(
        uint256 bondId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant returns (uint256 investId) {
        SalmonFarmBond storage b = bonds[bondId];
        euint64 amount = FHE.fromExternal(encAmount, proof);
        investId = investmentCount++;
        investments[investId] = BondInvestment({
            bondId: bondId, investor: msg.sender, investedAmountUSD: amount,
            couponEarnedUSD: FHE.asEuint64(0), investedAt: block.timestamp
        });
        FHE.allowThis(investments[investId].investedAmountUSD); FHE.allow(investments[investId].investedAmountUSD, msg.sender); FHE.allow(investments[investId].investedAmountUSD, b.farmOperator);
        FHE.allowThis(investments[investId].couponEarnedUSD); FHE.allow(investments[investId].couponEarnedUSD, msg.sender);
        emit InvestorSubbed(investId, bondId);
    }

    function allowCapitalStats(address viewer) external onlyOwner {
        FHE.allow(_totalBondCapitalUSD, viewer);
    }
}
