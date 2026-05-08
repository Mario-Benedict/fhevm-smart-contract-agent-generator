// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAgricultureCropInsurance
/// @notice Parametric crop insurance for agriculture: encrypted yield data, encrypted weather triggers,
///         encrypted premium calculations, encrypted indemnity payments, and confidential farm risk modeling.
contract EncryptedAgricultureCropInsurance is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CropType { WHEAT, CORN, SOYBEANS, COTTON, RICE, CANOLA, SUGARCANE }
    enum TriggerType { DROUGHT, FLOOD, FROST, WIND, PEST, PRICE_DROP }

    struct FarmPolicy {
        address farmer;
        CropType crop;
        euint64 insuredAreaHectares;   // encrypted farm area
        euint64 insuredYieldTonnesHa;  // encrypted guaranteed yield per hectare
        euint64 premiumUSD;            // encrypted annual premium
        euint64 maxPayoutUSD;          // encrypted max indemnity
        euint64 deductiblePct;         // encrypted deductible %
        euint64 historicalYieldAvg;    // encrypted historical avg yield
        uint256 coverageYear;
        bool active;
        bool claimed;
    }

    struct ClaimEvent {
        uint256 policyId;
        TriggerType trigger;
        euint64 actualYieldTonnesHa;  // encrypted actual yield
        euint64 yieldShortfall;       // encrypted shortfall vs insured
        euint64 weatherIndex;         // encrypted weather index score
        euint64 indemnityUSD;         // encrypted calculated payout
        uint256 eventDate;
        bool verified;
        bool paid;
    }

    struct WeatherStation {
        string stationId;
        string region;
        euint64 rainfallMm;           // encrypted rainfall reading
        euint64 temperatureC;         // encrypted temperature (scaled 10)
        euint64 droughtIndex;         // encrypted Palmer Drought Index (scaled 100)
        uint256 readingDate;
    }

    mapping(uint256 => FarmPolicy) private policies;
    mapping(uint256 => ClaimEvent[]) private claims;
    mapping(uint256 => WeatherStation) private stations;
    uint256 public policyCount;
    uint256 public stationCount;
    euint64 private _totalPremiumPool;
    euint64 private _totalClaimsPaid;
    mapping(address => bool) public isActuary;
    mapping(address => bool) public isWeatherOracle;
    mapping(address => bool) public isAdjuster;

    event PolicyIssued(uint256 indexed id, address farmer, CropType crop);
    event ClaimFiled(uint256 indexed policyId, uint256 claimIdx, TriggerType trigger);
    event ClaimVerified(uint256 indexed policyId, uint256 claimIdx);
    event IndemnityPaid(uint256 indexed policyId, uint256 claimIdx);
    event WeatherDataUpdated(uint256 indexed stationId);

    constructor() Ownable(msg.sender) {
        _totalPremiumPool = FHE.asEuint64(0);
        _totalClaimsPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalClaimsPaid);
        isActuary[msg.sender] = true;
        isWeatherOracle[msg.sender] = true;
        isAdjuster[msg.sender] = true;
    }

    function addActuary(address a) external onlyOwner { isActuary[a] = true; }
    function addOracle(address o) external onlyOwner { isWeatherOracle[o] = true; }
    function addAdjuster(address a) external onlyOwner { isAdjuster[a] = true; }

    function issuePolicy(
        address farmer, CropType crop,
        externalEuint64 encArea, bytes calldata aProof,
        externalEuint64 encYield, bytes calldata yProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint64 encMaxPayout, bytes calldata mpProof,
        externalEuint64 encHistYield, bytes calldata hyProof,
        uint256 year
    ) external returns (uint256 id) {
        require(isActuary[msg.sender], "Not actuary");
        euint64 area = FHE.fromExternal(encArea, aProof);
        euint64 yield_ = FHE.fromExternal(encYield, yProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint64 maxPayout = FHE.fromExternal(encMaxPayout, mpProof);
        euint64 histYield = FHE.fromExternal(encHistYield, hyProof);
        id = policyCount++;
        policies[id] = FarmPolicy({
            farmer: farmer, crop: crop, insuredAreaHectares: area,
            insuredYieldTonnesHa: yield_, premiumUSD: premium, maxPayoutUSD: maxPayout,
            deductiblePct: FHE.asEuint64(500), historicalYieldAvg: histYield,
            coverageYear: year, active: true, claimed: false
        });
        FHE.allowThis(policies[id].insuredAreaHectares);
        FHE.allowThis(policies[id].insuredYieldTonnesHa);
        FHE.allowThis(policies[id].premiumUSD);
        FHE.allowThis(policies[id].maxPayoutUSD);
        FHE.allowThis(policies[id].historicalYieldAvg);
        FHE.allow(policies[id].premiumUSD, farmer);
        FHE.allow(policies[id].maxPayoutUSD, farmer);
        emit PolicyIssued(id, farmer, crop);
    }

    function payPremium(uint256 policyId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(policies[policyId].farmer == msg.sender, "Not farmer");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalPremiumPool = FHE.add(_totalPremiumPool, amount);
        FHE.allowThis(_totalPremiumPool);
    }

    function fileClaim(
        uint256 policyId, TriggerType trigger,
        externalEuint64 encActualYield, bytes calldata ayProof,
        externalEuint64 encWeatherIndex, bytes calldata wiProof,
        uint256 eventDate
    ) external nonReentrant returns (uint256 claimIdx) {
        FarmPolicy storage pol = policies[policyId];
        require(pol.farmer == msg.sender && pol.active, "Not farmer or inactive");
        euint64 actualYield = FHE.fromExternal(encActualYield, ayProof);
        euint64 weatherIndex = FHE.fromExternal(encWeatherIndex, wiProof);
        // Shortfall = insured yield - actual yield
        ebool hasShortfall = FHE.gt(pol.insuredYieldTonnesHa, actualYield);
        euint64 shortfall = FHE.select(hasShortfall, FHE.sub(pol.insuredYieldTonnesHa, actualYield), FHE.asEuint64(0));
        // Indemnity = shortfall / insuredYield * maxPayout (simplified)
        euint64 indemnity = FHE.div(FHE.mul(shortfall, pol.maxPayoutUSD), pol.insuredYieldTonnesHa);
        // Apply deductible
        euint64 deductible = FHE.div(FHE.mul(indemnity, pol.deductiblePct), 10000);
        euint64 netIndemnity = FHE.sub(indemnity, deductible);
        claimIdx = claims[policyId].length;
        claims[policyId].push(ClaimEvent({
            policyId: policyId, trigger: trigger,
            actualYieldTonnesHa: actualYield, yieldShortfall: shortfall,
            weatherIndex: weatherIndex, indemnityUSD: netIndemnity,
            eventDate: eventDate, verified: false, paid: false
        }));
        FHE.allowThis(claims[policyId][claimIdx].actualYieldTonnesHa);
        FHE.allowThis(claims[policyId][claimIdx].yieldShortfall);
        FHE.allowThis(claims[policyId][claimIdx].weatherIndex);
        FHE.allowThis(claims[policyId][claimIdx].indemnityUSD);
        FHE.allow(claims[policyId][claimIdx].indemnityUSD, msg.sender);
        emit ClaimFiled(policyId, claimIdx, trigger);
    }

    function verifyClaim(uint256 policyId, uint256 claimIdx) external {
        require(isAdjuster[msg.sender], "Not adjuster");
        claims[policyId][claimIdx].verified = true;
        emit ClaimVerified(policyId, claimIdx);
    }

    function payIndemnity(uint256 policyId, uint256 claimIdx) external nonReentrant {
        require(isActuary[msg.sender], "Not actuary");
        ClaimEvent storage cl = claims[policyId][claimIdx];
        require(cl.verified && !cl.paid, "Not ready");
        ebool hasFunds = FHE.ge(_totalPremiumPool, cl.indemnityUSD);
        euint64 payout = FHE.select(hasFunds, cl.indemnityUSD, _totalPremiumPool);
        _totalPremiumPool = FHE.sub(_totalPremiumPool, payout);
        _totalClaimsPaid = FHE.add(_totalClaimsPaid, payout);
        cl.paid = true;
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalClaimsPaid);
        FHE.allow(payout, policies[policyId].farmer);
        emit IndemnityPaid(policyId, claimIdx);
    }

    function updateWeatherStation(
        uint256 stationId, string calldata stationIdStr, string calldata region,
        externalEuint64 encRain, bytes calldata rProof,
        externalEuint64 encTemp, bytes calldata tProof,
        externalEuint64 encDrought, bytes calldata dProof
    ) external {
        require(isWeatherOracle[msg.sender], "Not oracle");
        euint64 rain = FHE.fromExternal(encRain, rProof);
        euint64 temp = FHE.fromExternal(encTemp, tProof);
        euint64 drought = FHE.fromExternal(encDrought, dProof);
        if (stationId >= stationCount) stationCount = stationId + 1;
        stations[stationId] = WeatherStation({
            stationId: stationIdStr, region: region,
            rainfallMm: rain, temperatureC: temp, droughtIndex: drought,
            readingDate: block.timestamp
        });
        FHE.allowThis(stations[stationId].rainfallMm);
        FHE.allowThis(stations[stationId].temperatureC);
        FHE.allowThis(stations[stationId].droughtIndex);
        emit WeatherDataUpdated(stationId);
    }
}
