// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedWealthTaxRegistration
/// @notice Global wealth tax compliance: encrypted net worth declarations,
///         private asset disclosures, and confidential tax liability calculations.
///         Supports OECD CRS automatic exchange of encrypted financial data.
contract EncryptedWealthTaxRegistration is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum AssetClass { REAL_ESTATE, EQUITY, BONDS, CRYPTO, PRIVATE_BUSINESS, ART_COLLECTIBLES, CASH }
    enum TaxResidency { DOMESTIC, TREATY_COUNTRY, NON_TREATY_COUNTRY }

    struct WealthDeclaration {
        TaxResidency residency;
        euint64 totalNetWorthUSD;         // encrypted total net worth
        euint64 domesticAssetsUSD;        // encrypted domestic assets
        euint64 foreignAssetsUSD;         // encrypted foreign assets
        euint64 totalLiabilitiesUSD;      // encrypted total liabilities
        euint64 taxableWealthUSD;         // encrypted taxable wealth base
        euint64 wealthTaxDueUSD;          // encrypted calculated tax
        euint64 penaltyAmountUSD;         // encrypted penalties/interest
        euint64 priorYearWealthUSD;       // encrypted prior year for comparison
        uint256 declarationYear;
        uint256 submittedAt;
        bool verified;
        bool disputed;
    }

    struct AssetHolding {
        AssetClass assetClass;
        euint64 fairMarketValueUSD;       // encrypted FMV
        euint64 acquisitionCostUSD;       // encrypted cost basis
        euint64 unrealizedGainUSD;        // encrypted unrealized gain
        euint64 incomeGeneratedUSD;       // encrypted annual income
        bytes32 jurisdictionCode;
        uint256 acquisitionDate;
        bool reportedToForeignAuthority;
    }

    struct TaxBracket {
        euint64 thresholdUSD;             // encrypted bracket threshold
        euint64 rateBps;                  // encrypted tax rate for bracket
        bool active;
    }

    mapping(address => WealthDeclaration) private declarations;
    mapping(bytes32 => AssetHolding) private assets; // keccak(taxpayer, assetId)
    mapping(uint8 => TaxBracket) private taxBrackets;
    mapping(address => bool) public isTaxAuthority;
    mapping(address => bool) public isCertifiedAccountant;
    mapping(address => bool) public hasFiledThisYear;

    euint64 private _totalTaxCollected;
    euint64 private _systemTotalWealth;
    uint8 public bracketCount;

    event DeclarationFiled(address indexed taxpayer, uint256 year);
    event AssetDeclared(bytes32 indexed assetKey, address indexed taxpayer);
    event TaxAssessed(address indexed taxpayer, uint256 year);
    event TaxPaid(address indexed taxpayer, uint256 year);
    event DeclarationDisputed(address indexed taxpayer);

    constructor() Ownable(msg.sender) {
        _totalTaxCollected = FHE.asEuint64(0);
        _systemTotalWealth = FHE.asEuint64(0);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowThis(_systemTotalWealth);
        isTaxAuthority[msg.sender] = true;
        isCertifiedAccountant[msg.sender] = true;
    }

    modifier onlyTaxAuthority() { require(isTaxAuthority[msg.sender], "Not tax authority"); _; }

    function setTaxBracket(
        uint8 bracketId,
        externalEuint64 encThreshold, bytes calldata tProof,
        externalEuint64 encRate, bytes calldata rProof
    ) external onlyTaxAuthority {
        taxBrackets[bracketId].thresholdUSD = FHE.fromExternal(encThreshold, tProof);
        taxBrackets[bracketId].rateBps = FHE.fromExternal(encRate, rProof);
        taxBrackets[bracketId].active = true;
        if (bracketId >= bracketCount) bracketCount = bracketId + 1;
        FHE.allowThis(taxBrackets[bracketId].thresholdUSD);
        FHE.allowThis(taxBrackets[bracketId].rateBps);
    }

    function fileWealthDeclaration(
        TaxResidency residency,
        externalEuint64 encDomesticAssets, bytes calldata daProof,
        externalEuint64 encForeignAssets, bytes calldata faProof,
        externalEuint64 encLiabilities, bytes calldata lProof,
        uint256 declarationYear
    ) external nonReentrant {
        require(!hasFiledThisYear[msg.sender], "Already filed this year");
        euint64 domestic = FHE.fromExternal(encDomesticAssets, daProof);
        euint64 foreign = FHE.fromExternal(encForeignAssets, faProof);
        euint64 liabilities = FHE.fromExternal(encLiabilities, lProof);
        euint64 totalAssets = FHE.add(domestic, foreign);
        euint64 netWorth = FHE.sub(totalAssets, FHE.select(FHE.le(liabilities, totalAssets), liabilities, totalAssets));
        // Compute tax using brackets (simplified linear tax)
        euint64 taxDue = FHE.asEuint64(0);
        if (bracketCount > 0 && taxBrackets[0].active) {
            euint64 taxableBase = FHE.select(FHE.gt(netWorth, taxBrackets[0].thresholdUSD),
                FHE.sub(netWorth, taxBrackets[0].thresholdUSD), FHE.asEuint64(0));
            taxDue = FHE.div(FHE.mul(taxableBase, taxBrackets[0].rateBps), 10000);
        }
        WealthDeclaration storage wd = declarations[msg.sender];
        wd.residency = residency;
        wd.totalNetWorthUSD = netWorth;
        wd.domesticAssetsUSD = domestic;
        wd.foreignAssetsUSD = foreign;
        wd.totalLiabilitiesUSD = liabilities;
        wd.taxableWealthUSD = netWorth;
        wd.wealthTaxDueUSD = taxDue;
        wd.penaltyAmountUSD = FHE.asEuint64(0);
        wd.declarationYear = declarationYear;
        wd.submittedAt = block.timestamp;
        _systemTotalWealth = FHE.add(_systemTotalWealth, netWorth);
        hasFiledThisYear[msg.sender] = true;
        FHE.allowThis(wd.totalNetWorthUSD);
        FHE.allow(wd.totalNetWorthUSD, msg.sender);
        FHE.allowThis(wd.taxableWealthUSD);
        FHE.allow(wd.taxableWealthUSD, msg.sender);
        FHE.allowThis(wd.wealthTaxDueUSD);
        FHE.allow(wd.wealthTaxDueUSD, msg.sender);
        FHE.allowThis(wd.domesticAssetsUSD);
        FHE.allow(wd.domesticAssetsUSD, msg.sender);
        FHE.allowThis(wd.foreignAssetsUSD);
        FHE.allow(wd.foreignAssetsUSD, msg.sender);
        FHE.allowThis(_systemTotalWealth);
        emit DeclarationFiled(msg.sender, declarationYear);
    }

    function declareAsset(
        bytes32 assetId,
        AssetClass assetClass,
        externalEuint64 encFMV, bytes calldata fmvProof,
        externalEuint64 encCostBasis, bytes calldata cbProof,
        externalEuint64 encIncome, bytes calldata incProof,
        bytes32 jurisdictionCode,
        uint256 acquisitionDate
    ) external returns (bytes32 assetKey) {
        euint64 fmv = FHE.fromExternal(encFMV, fmvProof);
        euint64 costBasis = FHE.fromExternal(encCostBasis, cbProof);
        euint64 income = FHE.fromExternal(encIncome, incProof);
        euint64 unrealizedGain = FHE.select(FHE.ge(fmv, costBasis),
            FHE.sub(fmv, costBasis), FHE.asEuint64(0));
        assetKey = keccak256(abi.encodePacked(msg.sender, assetId));
        assets[assetKey] = AssetHolding({
            assetClass: assetClass, fairMarketValueUSD: fmv,
            acquisitionCostUSD: costBasis, unrealizedGainUSD: unrealizedGain,
            incomeGeneratedUSD: income, jurisdictionCode: jurisdictionCode,
            acquisitionDate: acquisitionDate, reportedToForeignAuthority: false
        });
        FHE.allowThis(assets[assetKey].fairMarketValueUSD);
        FHE.allow(assets[assetKey].fairMarketValueUSD, msg.sender);
        FHE.allowThis(assets[assetKey].unrealizedGainUSD);
        FHE.allow(assets[assetKey].unrealizedGainUSD, msg.sender);
        FHE.allowThis(assets[assetKey].incomeGeneratedUSD);
        FHE.allow(assets[assetKey].incomeGeneratedUSD, msg.sender);
        emit AssetDeclared(assetKey, msg.sender);
    }

    function assessTax(address taxpayer) external onlyTaxAuthority {
        WealthDeclaration storage wd = declarations[taxpayer];
        wd.verified = true;
        FHE.allow(wd.wealthTaxDueUSD, msg.sender);
        FHE.allow(wd.totalNetWorthUSD, msg.sender);
        FHE.allowTransient(wd.wealthTaxDueUSD, taxpayer);
        emit TaxAssessed(taxpayer, wd.declarationYear);
    }

    function payTax() external {
        WealthDeclaration storage wd = declarations[msg.sender];
        require(wd.verified, "Not yet assessed");
        _totalTaxCollected = FHE.add(_totalTaxCollected, wd.wealthTaxDueUSD);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowTransient(wd.wealthTaxDueUSD, msg.sender);
        emit TaxPaid(msg.sender, wd.declarationYear);
    }

    function disputeDeclaration() external {
        declarations[msg.sender].disputed = true;
        emit DeclarationDisputed(msg.sender);
    }

    function addTaxAuthority(address ta) external onlyOwner { isTaxAuthority[ta] = true; }
    function allowAggregateStats(address oecd) external onlyOwner {
        FHE.allow(_totalTaxCollected, oecd);
        FHE.allow(_systemTotalWealth, oecd);
    }
}
