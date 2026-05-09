// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateAgricultureCropFuturesExchange
/// @notice Encrypted futures market for agricultural commodities: confidential forward
///         contracts, private price discovery, and encrypted delivery obligations.
///         Supports seasonal hedging and margin call management.
contract PrivateAgricultureCropFuturesExchange is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum CropType { WHEAT, CORN, SOYBEANS, RICE, COTTON, COFFEE, COCOA, SUGARCANE }
    enum Season { SPRING, SUMMER, AUTUMN, WINTER }

    struct FuturesContract {
        CropType crop;
        Season deliverySeason;
        uint256 deliveryYear;
        euint64 contractSizeBushels;    // encrypted contract size
        euint64 currentFuturesPriceUSD; // encrypted current futures price per bushel
        euint64 settledPriceUSD;        // encrypted final settlement price
        euint64 totalOpenInterest;      // encrypted total open interest
        euint64 dailyPriceLimit;        // encrypted daily price limit (lock limit)
        uint256 expiryDate;
        bool settled;
        bool active;
    }

    struct FarmerPosition {
        address farmer;
        uint256 contractId;
        euint64 contractsHeld;         // encrypted number of futures contracts
        euint64 avgEntryPriceUSD;      // encrypted average entry price
        euint64 unrealizedPnLUSD;      // encrypted unrealised P&L
        euint64 marginPostedUSD;       // encrypted margin deposited
        euint64 maintenanceMarginUSD;  // encrypted maintenance margin level
        euint64 physicalHarvestEstKg;  // encrypted estimated physical harvest
        bool isHedger;
        bool isSpeculator;
        bool marginCallActive;
    }

    struct WeatherOracleData {
        uint256 contractId;
        euint64 rainfallMmEncrypted;   // encrypted rainfall data
        euint64 temperatureAvgK;       // encrypted average temperature (Kelvin scaled)
        euint64 yieldForecastBps;      // encrypted yield forecast vs baseline
        uint256 observationDate;
        bool priceAdjusted;
    }

    mapping(uint256 => FuturesContract) private futuresContracts;
    mapping(bytes32 => FarmerPosition) private positions; // keccak(farmer, contractId)
    mapping(uint256 => WeatherOracleData) private weatherData;
    mapping(address => euint64) private marginAccounts;
    mapping(address => bool) public isExchangeMember;
    mapping(address => bool) public isWeatherOracle;
    mapping(address => bool) public isDeliveryAgent;

    uint256 public contractCount;
    euint64 private _exchangeTotalVolume;
    euint64 private _totalMarginCollateral;
    euint64 private _exchangeFeeRateBps;

    event FuturesContractListed(uint256 indexed id, CropType crop, Season season, uint256 year);
    event PositionOpened(bytes32 indexed posKey, address farmer, bool isHedger);
    event PositionClosed(bytes32 indexed posKey);
    event MarginCallIssued(bytes32 indexed posKey);
    event MarginCallMet(bytes32 indexed posKey);
    event ContractSettled(uint256 indexed contractId);
    event WeatherDataSubmitted(uint256 indexed contractId, uint256 date);

    constructor(externalEuint64 encFeeRate, bytes memory frProof) Ownable(msg.sender) {
        _exchangeFeeRateBps = FHE.fromExternal(encFeeRate, frProof);
        _exchangeTotalVolume = FHE.asEuint64(0);
        _totalMarginCollateral = FHE.asEuint64(0);
        FHE.allowThis(_exchangeFeeRateBps);
        FHE.allowThis(_exchangeTotalVolume);
        FHE.allowThis(_totalMarginCollateral);
        isExchangeMember[msg.sender] = true;
        isWeatherOracle[msg.sender] = true;
        isDeliveryAgent[msg.sender] = true;
    }

    function listFuturesContract(
        CropType crop,
        Season season,
        uint256 year,
        externalEuint64 encContractSize, bytes calldata csProof,
        externalEuint64 encInitialPrice, bytes calldata ipProof,
        externalEuint64 encDailyLimit, bytes calldata dlProof,
        uint256 expiryDate
    ) external onlyOwner returns (uint256 id) {
        id = contractCount++;
        FuturesContract storage fc = futuresContracts[id];
        fc.crop = crop;
        fc.deliverySeason = season;
        fc.deliveryYear = year;
        fc.contractSizeBushels = FHE.fromExternal(encContractSize, csProof);
        fc.currentFuturesPriceUSD = FHE.fromExternal(encInitialPrice, ipProof);
        fc.settledPriceUSD = FHE.asEuint64(0);
        fc.totalOpenInterest = FHE.asEuint64(0);
        fc.dailyPriceLimit = FHE.fromExternal(encDailyLimit, dlProof);
        fc.expiryDate = expiryDate;
        fc.active = true;
        FHE.allowThis(fc.contractSizeBushels);
        FHE.allowThis(fc.currentFuturesPriceUSD);
        FHE.allowThis(fc.totalOpenInterest);
        FHE.allowThis(fc.dailyPriceLimit);
        emit FuturesContractListed(id, crop, season, year);
    }

    function depositMargin(externalEuint64 encMargin, bytes calldata mProof) external {
        require(isExchangeMember[msg.sender], "Not member");
        euint64 margin = FHE.fromExternal(encMargin, mProof);
        marginAccounts[msg.sender] = FHE.add(marginAccounts[msg.sender], margin);
        _totalMarginCollateral = FHE.add(_totalMarginCollateral, margin);
        FHE.allowThis(marginAccounts[msg.sender]);
        FHE.allow(marginAccounts[msg.sender], msg.sender);
        FHE.allowThis(_totalMarginCollateral);
    }

    function openFuturesPosition(
        uint256 contractId,
        bool isHedger,
        externalEuint64 encContracts, bytes calldata cProof,
        externalEuint64 encHarvestEstimate, bytes calldata heProof
    ) external nonReentrant returns (bytes32 posKey) {
        require(isExchangeMember[msg.sender], "Not member");
        FuturesContract storage fc = futuresContracts[contractId];
        require(fc.active && !fc.settled, "Contract not available");
        require(block.timestamp < fc.expiryDate, "Contract expired");
        euint64 numContracts = FHE.fromExternal(encContracts, cProof);
        euint64 harvestEst = FHE.fromExternal(encHarvestEstimate, heProof);
        // Initial margin = 10% of contract value
        euint64 contractValue = FHE.mul(FHE.mul(numContracts, fc.contractSizeBushels), fc.currentFuturesPriceUSD);
        euint64 initialMargin = FHE.div(contractValue, 10);
        euint64 maintenanceMargin = FHE.div(contractValue, 12); // ~8.3%
        // Check sufficient margin
        ebool hasSufficientMargin = FHE.ge(marginAccounts[msg.sender], initialMargin);
        euint64 actualContracts = FHE.select(hasSufficientMargin, numContracts, FHE.asEuint64(0));
        marginAccounts[msg.sender] = FHE.sub(marginAccounts[msg.sender],
            FHE.select(hasSufficientMargin, initialMargin, FHE.asEuint64(0)));
        fc.totalOpenInterest = FHE.add(fc.totalOpenInterest, actualContracts);
        posKey = keccak256(abi.encodePacked(msg.sender, contractId));
        positions[posKey] = FarmerPosition({
            farmer: msg.sender, contractId: contractId,
            contractsHeld: actualContracts,
            avgEntryPriceUSD: fc.currentFuturesPriceUSD,
            unrealizedPnLUSD: FHE.asEuint64(0),
            marginPostedUSD: FHE.select(hasSufficientMargin, initialMargin, FHE.asEuint64(0)),
            maintenanceMarginUSD: maintenanceMargin,
            physicalHarvestEstKg: harvestEst,
            isHedger: isHedger, isSpeculator: !isHedger,
            marginCallActive: false
        });
        _exchangeTotalVolume = FHE.add(_exchangeTotalVolume, contractValue);
        FHE.allowThis(positions[posKey].contractsHeld);
        FHE.allow(positions[posKey].contractsHeld, msg.sender);
        FHE.allowThis(positions[posKey].unrealizedPnLUSD);
        FHE.allow(positions[posKey].unrealizedPnLUSD, msg.sender);
        FHE.allowThis(positions[posKey].marginPostedUSD);
        FHE.allow(positions[posKey].marginPostedUSD, msg.sender);
        FHE.allowThis(marginAccounts[msg.sender]);
        FHE.allow(marginAccounts[msg.sender], msg.sender);
        FHE.allowThis(fc.totalOpenInterest);
        FHE.allowThis(_exchangeTotalVolume);
        emit PositionOpened(posKey, msg.sender, isHedger);
    }

    function updateFuturesPrice(
        uint256 contractId,
        externalEuint64 encNewPrice, bytes calldata npProof
    ) external {
        require(isWeatherOracle[msg.sender] || isExchangeMember[msg.sender], "Unauthorized");
        FuturesContract storage fc = futuresContracts[contractId];
        euint64 newPrice = FHE.fromExternal(encNewPrice, npProof);
        // Enforce daily price limit
        ebool priceUp = FHE.ge(newPrice, fc.currentFuturesPriceUSD);
        euint64 priceDiff = FHE.select(priceUp,
            FHE.sub(newPrice, fc.currentFuturesPriceUSD),
            FHE.sub(fc.currentFuturesPriceUSD, newPrice));
        ebool withinLimit = FHE.le(priceDiff, fc.dailyPriceLimit);
        euint64 clampedPrice = FHE.select(withinLimit, newPrice,
            FHE.select(priceUp,
                FHE.add(fc.currentFuturesPriceUSD, fc.dailyPriceLimit),
                FHE.sub(fc.currentFuturesPriceUSD, fc.dailyPriceLimit)));
        fc.currentFuturesPriceUSD = clampedPrice;
        FHE.allowThis(fc.currentFuturesPriceUSD);
    }

    function issueMarginCall(bytes32 posKey) external onlyOwner {
        FarmerPosition storage p = positions[posKey];
        FuturesContract storage fc = futuresContracts[p.contractId];
        // Current value vs maintenance margin
        euint64 currentValue = FHE.mul(FHE.mul(p.contractsHeld, fc.contractSizeBushels), fc.currentFuturesPriceUSD);
        euint64 currentMarginValue = FHE.div(currentValue, 12);
        ebool marginDeficient = FHE.lt(p.marginPostedUSD, currentMarginValue);
        // marginDeficient is encrypted; owner calling this function signals active margin call
        p.marginCallActive = FHE.isInitialized(marginDeficient);
        if (p.marginCallActive) {
            emit MarginCallIssued(posKey);
        }
    }

    function meetMarginCall(bytes32 posKey, externalEuint64 encTopUp, bytes calldata tuProof) external {
        FarmerPosition storage p = positions[posKey];
        require(p.farmer == msg.sender && p.marginCallActive, "No margin call");
        euint64 topUp = FHE.fromExternal(encTopUp, tuProof);
        p.marginPostedUSD = FHE.add(p.marginPostedUSD, topUp);
        marginAccounts[msg.sender] = FHE.sub(marginAccounts[msg.sender], topUp);
        p.marginCallActive = false;
        FHE.allowThis(p.marginPostedUSD);
        FHE.allow(p.marginPostedUSD, msg.sender);
        FHE.allowThis(marginAccounts[msg.sender]);
        FHE.allow(marginAccounts[msg.sender], msg.sender);
        emit MarginCallMet(posKey);
    }

    function submitWeatherData(
        uint256 contractId,
        externalEuint64 encRainfall, bytes calldata rfProof,
        externalEuint64 encTemp, bytes calldata tempProof,
        externalEuint64 encYieldForecast, bytes calldata yfProof
    ) external {
        require(isWeatherOracle[msg.sender], "Not weather oracle");
        weatherData[contractId] = WeatherOracleData({
            contractId: contractId,
            rainfallMmEncrypted: FHE.fromExternal(encRainfall, rfProof),
            temperatureAvgK: FHE.fromExternal(encTemp, tempProof),
            yieldForecastBps: FHE.fromExternal(encYieldForecast, yfProof),
            observationDate: block.timestamp,
            priceAdjusted: false
        });
        FHE.allowThis(weatherData[contractId].rainfallMmEncrypted);
        FHE.allowThis(weatherData[contractId].temperatureAvgK);
        FHE.allowThis(weatherData[contractId].yieldForecastBps);
        emit WeatherDataSubmitted(contractId, block.timestamp);
    }

    function settleContract(
        uint256 contractId,
        externalEuint64 encSettlementPrice, bytes calldata spProof
    ) external onlyOwner {
        FuturesContract storage fc = futuresContracts[contractId];
        require(!fc.settled && block.timestamp >= fc.expiryDate, "Not yet expired");
        fc.settledPriceUSD = FHE.fromExternal(encSettlementPrice, spProof);
        fc.settled = true;
        FHE.allowThis(fc.settledPriceUSD);
        emit ContractSettled(contractId);
    }

    function addExchangeMember(address m) external onlyOwner { isExchangeMember[m] = true; }
    function addWeatherOracle(address o) external onlyOwner { isWeatherOracle[o] = true; }
    function allowExchangeStats(address regulator) external onlyOwner {
        FHE.allow(_exchangeTotalVolume, regulator);
        FHE.allow(_totalMarginCollateral, regulator);
    }
}
