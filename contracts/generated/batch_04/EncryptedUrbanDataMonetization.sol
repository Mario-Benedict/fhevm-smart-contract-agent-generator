// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedUrbanDataMonetization
/// @notice Smart city data marketplace: encrypted citizen mobility patterns, encrypted energy consumption,
///         encrypted air quality sensor data, and private commercial licensing of aggregated city data.
contract EncryptedUrbanDataMonetization is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum DataType { MOBILITY, ENERGY, AIR_QUALITY, NOISE, WASTE, TRAFFIC, CROWD_DENSITY }
    enum DataGranularity { NEIGHBORHOOD, DISTRICT, CITY_WIDE }

    struct DataStream {
        string streamName;
        DataType dataType;
        DataGranularity granularity;
        string sensorNetwork;
        euint64 dailyDataPoints;       // encrypted data points per day
        euint64 pricingTierUSD;        // encrypted pricing per access period
        euint64 totalRevenue;          // encrypted lifetime revenue
        euint64 privacyBudgetEpsilon;  // encrypted differential privacy epsilon (scaled 100)
        bool active;
        address publisher;
    }

    struct DataLicense {
        uint256 streamId;
        address licensee;
        euint64 paidAmountUSD;         // encrypted amount paid
        euint64 accessQuota;           // encrypted data access quota (API calls)
        euint64 usedQuota;             // encrypted quota used
        uint256 licenseStart;
        uint256 licenseEnd;
        bool active;
    }

    struct AggregatedReading {
        uint256 streamId;
        euint64 aggregateValue;       // encrypted aggregate (mean, sum etc.)
        euint64 privacyNoiseLevel;    // encrypted Laplace noise added
        uint256 readingDate;
        string unit;
        DataGranularity granularity;
    }

    mapping(uint256 => DataStream) private streams;
    mapping(uint256 => DataLicense) private licenses;
    mapping(uint256 => AggregatedReading[]) private readings;
    uint256 public streamCount;
    uint256 public licenseCount;
    euint64 private _totalCityDataRevenue;
    euint64 private _privacyComplianceScore;  // city-wide compliance metric
    mapping(address => bool) public isCityAdmin;
    mapping(address => bool) public isSensorOperator;
    mapping(address => bool) public isDataBroker;

    event StreamRegistered(uint256 indexed id, string name, DataType dtype);
    event LicenseIssued(uint256 indexed licenseId, uint256 streamId, address licensee);
    event ReadingPublished(uint256 indexed streamId, uint256 readingIdx);
    event QuotaConsumed(uint256 indexed licenseId);
    event PrivacyBudgetUpdated(uint256 indexed streamId);

    constructor() Ownable(msg.sender) {
        _totalCityDataRevenue = FHE.asEuint64(0);
        _privacyComplianceScore = FHE.asEuint64(900);
        FHE.allowThis(_totalCityDataRevenue);
        FHE.allowThis(_privacyComplianceScore);
        isCityAdmin[msg.sender] = true;
        isSensorOperator[msg.sender] = true;
        isDataBroker[msg.sender] = true;
    }

    function addAdmin(address a) external onlyOwner { isCityAdmin[a] = true; }
    function addOperator(address o) external onlyOwner { isSensorOperator[o] = true; }
    function addBroker(address b) external onlyOwner { isDataBroker[b] = true; }

    function registerStream(
        string calldata name, DataType dtype, DataGranularity granularity,
        string calldata sensorNetwork,
        externalEuint64 encDataPoints, bytes calldata dpProof,
        externalEuint64 encPricing, bytes calldata prProof,
        externalEuint64 encEpsilon, bytes calldata epProof
    ) external returns (uint256 id) {
        require(isCityAdmin[msg.sender], "Not admin");
        euint64 dataPoints = FHE.fromExternal(encDataPoints, dpProof);
        euint64 pricing = FHE.fromExternal(encPricing, prProof);
        euint64 epsilon = FHE.fromExternal(encEpsilon, epProof);
        id = streamCount++;
        streams[id].streamName = name;
        streams[id].dataType = dtype;
        streams[id].granularity = granularity;
        streams[id].sensorNetwork = sensorNetwork;
        streams[id].dailyDataPoints = dataPoints;
        streams[id].pricingTierUSD = pricing;
        streams[id].totalRevenue = FHE.asEuint64(0);
        streams[id].privacyBudgetEpsilon = epsilon;
        streams[id].active = true;
        streams[id].publisher = msg.sender;
        FHE.allowThis(streams[id].dailyDataPoints);
        FHE.allowThis(streams[id].pricingTierUSD);
        FHE.allowThis(streams[id].totalRevenue);
        FHE.allowThis(streams[id].privacyBudgetEpsilon);
        emit StreamRegistered(id, name, dtype);
    }

    function issueLicense(
        uint256 streamId, address licensee,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint64 encQuota, bytes calldata qProof,
        uint256 duration
    ) external nonReentrant returns (uint256 licId) {
        require(isDataBroker[msg.sender], "Not broker");
        DataStream storage stream = streams[streamId];
        require(stream.active, "Stream inactive");
        euint64 amount = FHE.fromExternal(encAmount, aProof);
        euint64 quota = FHE.fromExternal(encQuota, qProof);
        licId = licenseCount++;
        licenses[licId] = DataLicense({
            streamId: streamId, licensee: licensee,
            paidAmountUSD: amount, accessQuota: quota,
            usedQuota: FHE.asEuint64(0),
            licenseStart: block.timestamp, licenseEnd: block.timestamp + duration,
            active: true
        });
        stream.totalRevenue = FHE.add(stream.totalRevenue, amount);
        _totalCityDataRevenue = FHE.add(_totalCityDataRevenue, amount);
        FHE.allowThis(licenses[licId].paidAmountUSD);
        FHE.allowThis(licenses[licId].accessQuota);
        FHE.allowThis(licenses[licId].usedQuota);
        FHE.allow(licenses[licId].accessQuota, licensee);
        FHE.allow(licenses[licId].usedQuota, licensee);
        FHE.allowThis(stream.totalRevenue);
        FHE.allowThis(_totalCityDataRevenue);
        emit LicenseIssued(licId, streamId, licensee);
    }

    function publishReading(
        uint256 streamId, string calldata unit, DataGranularity granularity,
        externalEuint64 encAggregate, bytes calldata agProof,
        externalEuint64 encNoise, bytes calldata nProof
    ) external returns (uint256 readingIdx) {
        require(isSensorOperator[msg.sender], "Not operator");
        euint64 aggregate = FHE.fromExternal(encAggregate, agProof);
        euint64 noise = FHE.fromExternal(encNoise, nProof);
        // Apply privacy noise (conceptual)
        euint64 noisyValue = FHE.add(aggregate, noise);
        readingIdx = readings[streamId].length;
        readings[streamId].push(AggregatedReading({
            streamId: streamId, aggregateValue: noisyValue,
            privacyNoiseLevel: noise, readingDate: block.timestamp,
            unit: unit, granularity: granularity
        }));
        FHE.allowThis(readings[streamId][readingIdx].aggregateValue);
        FHE.allowThis(readings[streamId][readingIdx].privacyNoiseLevel);
        emit ReadingPublished(streamId, readingIdx);
    }

    function consumeQuota(uint256 licenseId) external {
        DataLicense storage lic = licenses[licenseId];
        require(lic.licensee == msg.sender && lic.active, "Not licensee");
        require(block.timestamp < lic.licenseEnd, "License expired");
        ebool hasQuota = FHE.gt(lic.accessQuota, lic.usedQuota);
        lic.usedQuota = FHE.select(hasQuota, FHE.add(lic.usedQuota, FHE.asEuint64(1)), lic.usedQuota);
        FHE.allowThis(lic.usedQuota);
        FHE.allow(lic.usedQuota, msg.sender);
        emit QuotaConsumed(licenseId);
    }

    function grantLicenseeView(uint256 streamId, uint256 readingIdx, address licensee) external {
        require(isDataBroker[msg.sender], "Not broker");
        FHE.allow(readings[streamId][readingIdx].aggregateValue, licensee);
    }

    function updatePrivacyBudget(uint256 streamId, externalEuint64 encEpsilon, bytes calldata proof) external {
        require(isCityAdmin[msg.sender], "Not admin");
        streams[streamId].privacyBudgetEpsilon = FHE.fromExternal(encEpsilon, proof);
        FHE.allowThis(streams[streamId].privacyBudgetEpsilon);
        emit PrivacyBudgetUpdated(streamId);
    }
}
