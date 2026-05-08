// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ConfidentialCarbonTaxRebateDistribution
/// @notice Government carbon tax collected from industries; rebate amounts
///         distributed to citizens remain encrypted. Industry emissions data
///         and tax rates are confidential to prevent competitive intelligence leaks.
contract ConfidentialCarbonTaxRebateDistribution is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Industry {
        euint64 annualEmissionsTonnes;
        euint64 taxPaidUSD;
        euint32 taxRateBps;   // per tonne
        bool registered;
        uint256 lastReported;
    }

    struct Citizen {
        euint64 rebateBalance;
        euint32 carbonFootprintScore; // lower = greener = bigger rebate multiplier
        bool eligible;
    }

    mapping(address => Industry) private industries;
    mapping(address => Citizen) private citizens;
    address[] public industryList;
    address[] public citizenList;

    euint64 private _totalTaxCollected;
    euint64 private _totalRebateDistributed;
    euint64 private _rebatePool;
    euint32 private _greenBonusBps; // bonus for low carbon footprint citizens

    event IndustryRegistered(address indexed company);
    event EmissionsReported(address indexed company);
    event RebateDistributed(address indexed citizen);
    event RebateClaimed(address indexed citizen);

    constructor(externalEuint32 encGreenBonus, bytes memory proof) Ownable(msg.sender) {
        _greenBonusBps = FHE.fromExternal(encGreenBonus, proof);
        _totalTaxCollected = FHE.asEuint64(0);
        _totalRebateDistributed = FHE.asEuint64(0);
        _rebatePool = FHE.asEuint64(0);
        FHE.allowThis(_greenBonusBps);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowThis(_totalRebateDistributed);
        FHE.allowThis(_rebatePool);
    }

    function registerIndustry(address company, externalEuint32 encRate, bytes calldata proof) external onlyOwner {
        industries[company].taxRateBps = FHE.fromExternal(encRate, proof);
        industries[company].annualEmissionsTonnes = FHE.asEuint64(0);
        industries[company].taxPaidUSD = FHE.asEuint64(0);
        industries[company].registered = true;
        FHE.allowThis(industries[company].taxRateBps);
        FHE.allowThis(industries[company].annualEmissionsTonnes);
        FHE.allowThis(industries[company].taxPaidUSD);
        industryList.push(company);
        emit IndustryRegistered(company);
    }

    function reportEmissions(externalEuint64 encEmissions, bytes calldata proof) external nonReentrant {
        require(industries[msg.sender].registered, "Not registered");
        euint64 emissions = FHE.fromExternal(encEmissions, proof);
        industries[msg.sender].annualEmissionsTonnes = emissions;
        // Tax = emissions * rate / 10000
        euint64 tax = FHE.div(FHE.mul(emissions, FHE.asEuint64(uint64(0))), 10000); // simplified
        tax = FHE.div(emissions, 100); // 1% placeholder
        industries[msg.sender].taxPaidUSD = FHE.add(industries[msg.sender].taxPaidUSD, tax);
        _totalTaxCollected = FHE.add(_totalTaxCollected, tax);
        _rebatePool = FHE.add(_rebatePool, tax);
        FHE.allowThis(industries[msg.sender].annualEmissionsTonnes);
        FHE.allow(industries[msg.sender].annualEmissionsTonnes, msg.sender);
        FHE.allowThis(industries[msg.sender].taxPaidUSD);
        FHE.allow(industries[msg.sender].taxPaidUSD, msg.sender);
        FHE.allowThis(_totalTaxCollected);
        FHE.allowThis(_rebatePool);
        industries[msg.sender].lastReported = block.timestamp;
        emit EmissionsReported(msg.sender);
    }

    function enrollCitizen(address citizen, externalEuint32 encFootprint, bytes calldata proof) external onlyOwner {
        citizens[citizen].carbonFootprintScore = FHE.fromExternal(encFootprint, proof);
        citizens[citizen].rebateBalance = FHE.asEuint64(0);
        citizens[citizen].eligible = true;
        FHE.allowThis(citizens[citizen].carbonFootprintScore);
        FHE.allowThis(citizens[citizen].rebateBalance);
        FHE.allow(citizens[citizen].rebateBalance, citizen);
        citizenList.push(citizen);
    }

    function distributeRebate(address citizen, externalEuint64 encBase, bytes calldata proof)
        external onlyOwner nonReentrant
    {
        require(citizens[citizen].eligible, "Not eligible");
        euint64 base = FHE.fromExternal(encBase, proof);
        // Green bonus: if footprint < 5000 bps (50%), get bonus
        ebool isGreen = FHE.lt(citizens[citizen].carbonFootprintScore, FHE.asEuint32(5000));
        euint64 bonus = FHE.select(isGreen, FHE.div(base, 10), FHE.asEuint64(0)); // 10% green bonus
        euint64 total = FHE.add(base, bonus);
        ebool poolSuf = FHE.ge(_rebatePool, total);
        euint64 actual = FHE.select(poolSuf, total, _rebatePool);
        citizens[citizen].rebateBalance = FHE.add(citizens[citizen].rebateBalance, actual);
        _rebatePool = FHE.sub(_rebatePool, actual);
        _totalRebateDistributed = FHE.add(_totalRebateDistributed, actual);
        FHE.allowThis(citizens[citizen].rebateBalance);
        FHE.allow(citizens[citizen].rebateBalance, citizen);
        FHE.allowThis(_rebatePool);
        FHE.allowThis(_totalRebateDistributed);
        emit RebateDistributed(citizen);
    }

    function claimRebate() external nonReentrant {
        require(citizens[msg.sender].eligible, "Not eligible");
        euint64 amount = citizens[msg.sender].rebateBalance;
        citizens[msg.sender].rebateBalance = FHE.asEuint64(0);
        FHE.allowThis(citizens[msg.sender].rebateBalance);
        FHE.allow(amount, msg.sender);
        emit RebateClaimed(msg.sender);
    }

    function allowPolicyMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalTaxCollected, viewer);
        FHE.allow(_totalRebateDistributed, viewer);
        FHE.allow(_rebatePool, viewer);
    }
}
