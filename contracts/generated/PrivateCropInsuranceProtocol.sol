// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCropInsuranceProtocol
/// @notice Parametric crop insurance: farmers register encrypted acreage and crop type.
///         Satellite/oracle reports encrypted rainfall/yield index. Payout auto-triggers
///         when encrypted index falls below encrypted strike threshold.
contract PrivateCropInsuranceProtocol is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CropType { Wheat, Corn, Soybean, Cotton, Rice }
    enum PolicyStatus { Active, Triggered, Settled, Expired }

    struct CropPolicy {
        address farmer;
        CropType cropType;
        string region;
        euint32 insuredAcres;          // encrypted acres insured
        euint64 sumInsuredUSD;         // encrypted total insured value
        euint64 premiumPaidUSD;        // encrypted premium amount
        euint16 strikeRainfallMM;      // encrypted rainfall strike (trigger below this)
        euint16 observedRainfallMM;    // encrypted oracle-reported rainfall
        euint64 payoutAmountUSD;       // encrypted payout triggered
        uint256 seasonStart;
        uint256 seasonEnd;
        PolicyStatus status;
    }

    mapping(uint256 => CropPolicy) private policies;
    mapping(address => uint256[]) private farmerPolicies;
    mapping(address => bool) public isWeatherOracle;
    mapping(address => bool) public isUnderwriter;
    uint256 public policyCount;
    euint64 private _totalInsuredValue;
    euint64 private _totalPremiumPool;
    euint64 private _totalPayoutsIssued;

    event PolicyCreated(uint256 indexed id, CropType crop, string region);
    event RainfallReported(uint256 indexed id, string region);
    event PayoutTriggered(uint256 indexed id, address farmer);
    event PolicySettled(uint256 indexed id);
    event PolicyExpired(uint256 indexed id);

    modifier onlyOracle() {
        require(isWeatherOracle[msg.sender] || msg.sender == owner(), "Not oracle");
        _;
    }

    modifier onlyUnderwriter() {
        require(isUnderwriter[msg.sender] || msg.sender == owner(), "Not underwriter");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalInsuredValue = FHE.asEuint64(0);
        _totalPremiumPool = FHE.asEuint64(0);
        _totalPayoutsIssued = FHE.asEuint64(0);
        FHE.allowThis(_totalInsuredValue);
        FHE.allowThis(_totalPremiumPool);
        FHE.allowThis(_totalPayoutsIssued);
        isWeatherOracle[msg.sender] = true;
        isUnderwriter[msg.sender] = true;
    }

    function addOracle(address o) external onlyOwner { isWeatherOracle[o] = true; }
    function addUnderwriter(address u) external onlyOwner { isUnderwriter[u] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createPolicy(
        CropType crop,
        string calldata region,
        externalEuint32 encAcres, bytes calldata aProof,
        externalEuint64 encSumInsured, bytes calldata siProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint16 encStrike, bytes calldata stProof,
        uint256 seasonDays
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        euint32 acres = FHE.fromExternal(encAcres, aProof);
        euint64 sumInsured = FHE.fromExternal(encSumInsured, siProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint16 strike = FHE.fromExternal(encStrike, stProof);
        id = policyCount++;
        policies[id] = CropPolicy({
            farmer: msg.sender, cropType: crop, region: region,
            insuredAcres: acres, sumInsuredUSD: sumInsured, premiumPaidUSD: premium,
            strikeRainfallMM: strike, observedRainfallMM: FHE.asEuint16(0),
            payoutAmountUSD: FHE.asEuint64(0),
            seasonStart: block.timestamp, seasonEnd: block.timestamp + seasonDays * 1 days,
            status: PolicyStatus.Active
        });
        _totalInsuredValue = FHE.add(_totalInsuredValue, sumInsured);
        _totalPremiumPool = FHE.add(_totalPremiumPool, premium);
        FHE.allowThis(policies[id].insuredAcres);
        FHE.allow(policies[id].insuredAcres, msg.sender);
        FHE.allowThis(policies[id].sumInsuredUSD);
        FHE.allow(policies[id].sumInsuredUSD, msg.sender);
        FHE.allowThis(policies[id].premiumPaidUSD);
        FHE.allowThis(policies[id].strikeRainfallMM);
        FHE.allow(policies[id].strikeRainfallMM, msg.sender);
        FHE.allowThis(policies[id].observedRainfallMM);
        FHE.allowThis(policies[id].payoutAmountUSD);
        FHE.allowThis(_totalInsuredValue);
        FHE.allowThis(_totalPremiumPool);
        farmerPolicies[msg.sender].push(id);
        emit PolicyCreated(id, crop, region);
    }

    function reportRainfall(
        uint256 policyId,
        externalEuint16 encRainfall, bytes calldata proof
    ) external onlyOracle {
        CropPolicy storage p = policies[policyId];
        require(p.status == PolicyStatus.Active, "Not active");
        euint16 rainfall = FHE.fromExternal(encRainfall, proof);
        p.observedRainfallMM = rainfall;
        FHE.allowThis(p.observedRainfallMM);
        FHE.allow(p.observedRainfallMM, p.farmer);
        // Auto-check trigger: payout if observed < strike
        ebool triggered = FHE.lt(rainfall, p.strikeRainfallMM);
        euint64 payout = FHE.select(triggered, p.sumInsuredUSD, FHE.asEuint64(0));
        p.payoutAmountUSD = payout;
        FHE.allowThis(p.payoutAmountUSD);
        FHE.allow(p.payoutAmountUSD, p.farmer);
        if (FHE.isInitialized(triggered)) {
            p.status = PolicyStatus.Triggered;
            emit PayoutTriggered(policyId, p.farmer);
        }
        emit RainfallReported(policyId, p.region);
    }

    function settlePayout(uint256 policyId) external onlyUnderwriter nonReentrant {
        CropPolicy storage p = policies[policyId];
        require(p.status == PolicyStatus.Triggered, "Not triggered");
        p.status = PolicyStatus.Settled;
        _totalPayoutsIssued = FHE.add(_totalPayoutsIssued, p.payoutAmountUSD);
        _totalPremiumPool = FHE.sub(_totalPremiumPool, p.payoutAmountUSD);
        FHE.allowThis(_totalPayoutsIssued);
        FHE.allowThis(_totalPremiumPool);
        FHE.allow(p.payoutAmountUSD, p.farmer);
        emit PolicySettled(policyId);
    }

    function expirePolicy(uint256 policyId) external {
        CropPolicy storage p = policies[policyId];
        require(p.status == PolicyStatus.Active && block.timestamp > p.seasonEnd, "Cannot expire");
        p.status = PolicyStatus.Expired;
        emit PolicyExpired(policyId);
    }

    function allowPolicyDetails(uint256 policyId, address viewer) external {
        CropPolicy storage p = policies[policyId];
        require(msg.sender == p.farmer || isUnderwriter[msg.sender] || isWeatherOracle[msg.sender], "Unauthorized");
        FHE.allow(p.insuredAcres, viewer);
        FHE.allow(p.sumInsuredUSD, viewer);
        FHE.allow(p.strikeRainfallMM, viewer);
        FHE.allow(p.observedRainfallMM, viewer);
        FHE.allow(p.payoutAmountUSD, viewer);
    }

    function allowPortfolioStats(address viewer) external onlyOwner {
        FHE.allow(_totalInsuredValue, viewer);
        FHE.allow(_totalPremiumPool, viewer);
        FHE.allow(_totalPayoutsIssued, viewer);
    }
}
