// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateBankingWealth
/// @notice Private banking: HNW client profiles with encrypted AUM, encrypted
///         risk profile, encrypted fee tiers, and relationship manager access.
contract EncryptedPrivateBankingWealth is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum RiskProfile { Conservative, Moderate, Balanced, Growth, Aggressive }
    enum ClientTier { Affluent, HighNetWorth, VeryHighNetWorth, UltraHighNetWorth, Family }

    struct WealthProfile {
        string clientCode;             // non-sensitive code
        euint64 aumUSD;                // encrypted assets under management
        euint64 liquidAssetUSD;        // encrypted liquid holdings
        euint64 realEstateValueUSD;    // encrypted real estate
        euint64 alternativesUSD;       // encrypted alternatives (PE/HF)
        euint8  riskScore;             // encrypted risk appetite 0-100
        euint64 annualFeeUSD;          // encrypted annual management fee
        euint64 unrealizedGainUSD;     // encrypted unrealized capital gain
        RiskProfile riskProfile;
        ClientTier tier;
        address relationshipManager;
        uint256 onboardedAt;
        bool active;
    }

    struct PortfolioRebalance {
        address client;
        euint64 equityAllocationBps;   // encrypted target equity %
        euint64 bondAllocationBps;     // encrypted target bond %
        euint64 altAllocationBps;      // encrypted target alts %
        euint64 cashAllocationBps;     // encrypted target cash %
        uint256 rebalancedAt;
        bool approved;
    }

    mapping(address => WealthProfile) private profiles;
    mapping(uint256 => PortfolioRebalance) private rebalances;
    mapping(address => bool) public isRelationshipManager;
    mapping(address => bool) public isComplianceOfficer;
    mapping(address => bool) public isClient;
    uint256 public rebalanceCount;
    euint64 private _totalBankAUM;
    euint64 private _totalFeesEarned;

    event ClientOnboarded(address indexed client, string clientCode);
    event AUMUpdated(address indexed client);
    event RebalanceProposed(uint256 indexed id, address client);
    event RebalanceApproved(uint256 indexed id);
    event FeeCharged(address indexed client);

    modifier onlyRM() {
        require(isRelationshipManager[msg.sender] || msg.sender == owner(), "Not RM");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalBankAUM = FHE.asEuint64(0);
        _totalFeesEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalBankAUM);
        FHE.allowThis(_totalFeesEarned);
        isRelationshipManager[msg.sender] = true;
        isComplianceOfficer[msg.sender] = true;
    }

    function addRM(address rm) external onlyOwner { isRelationshipManager[rm] = true; }
    function addComplianceOfficer(address co) external onlyOwner { isComplianceOfficer[co] = true; }

    function onboardClient(
        address client, string calldata clientCode,
        externalEuint64 encAUM, bytes calldata aumPf,
        externalEuint64 encLiquid, bytes calldata liqPf,
        externalEuint64 encRealEstate, bytes calldata rePf,
        externalEuint64 encAlts, bytes calldata altsPf,
        externalEuint8 encRisk, bytes calldata riskPf,
        externalEuint64 encFee, bytes calldata feePf,
        RiskProfile riskProfile, ClientTier tier
    ) external onlyRM {
        euint64 aum = FHE.fromExternal(encAUM, aumPf);
        euint64 liquid = FHE.fromExternal(encLiquid, liqPf);
        euint64 realEstate = FHE.fromExternal(encRealEstate, rePf);
        euint64 alts = FHE.fromExternal(encAlts, altsPf);
        euint8 riskScore = FHE.fromExternal(encRisk, riskPf);
        euint64 fee = FHE.fromExternal(encFee, feePf);
        profiles[client] = WealthProfile({
            clientCode: clientCode, aumUSD: aum, liquidAssetUSD: liquid,
            realEstateValueUSD: realEstate, alternativesUSD: alts,
            riskScore: riskScore, annualFeeUSD: fee, unrealizedGainUSD: FHE.asEuint64(0),
            riskProfile: riskProfile, tier: tier, relationshipManager: msg.sender,
            onboardedAt: block.timestamp, active: true
        });
        isClient[client] = true;
        _totalBankAUM = FHE.add(_totalBankAUM, aum);
        FHE.allowThis(profiles[client].aumUSD);
        FHE.allow(profiles[client].aumUSD, client);
        FHE.allow(profiles[client].aumUSD, msg.sender);
        FHE.allowThis(profiles[client].liquidAssetUSD);
        FHE.allow(profiles[client].liquidAssetUSD, client);
        FHE.allowThis(profiles[client].realEstateValueUSD);
        FHE.allow(profiles[client].realEstateValueUSD, client);
        FHE.allowThis(profiles[client].alternativesUSD);
        FHE.allowThis(profiles[client].riskScore);
        FHE.allow(profiles[client].riskScore, client);
        FHE.allow(profiles[client].riskScore, msg.sender);
        FHE.allowThis(profiles[client].annualFeeUSD);
        FHE.allow(profiles[client].annualFeeUSD, client);
        FHE.allowThis(profiles[client].unrealizedGainUSD);
        FHE.allowThis(_totalBankAUM);
        emit ClientOnboarded(client, clientCode);
    }

    function updateAUM(address client, externalEuint64 encNewAUM, bytes calldata proof) external onlyRM {
        euint64 newAUM = FHE.fromExternal(encNewAUM, proof);
        _totalBankAUM = FHE.sub(_totalBankAUM, profiles[client].aumUSD);
        profiles[client].aumUSD = newAUM;
        _totalBankAUM = FHE.add(_totalBankAUM, newAUM);
        FHE.allowThis(profiles[client].aumUSD);
        FHE.allow(profiles[client].aumUSD, client);
        FHE.allow(profiles[client].aumUSD, msg.sender);
        FHE.allowThis(_totalBankAUM);
        emit AUMUpdated(client);
    }

    function proposeRebalance(
        address client,
        externalEuint64 encEquity, bytes calldata eqPf,
        externalEuint64 encBond, bytes calldata bdPf,
        externalEuint64 encAlts, bytes calldata altPf,
        externalEuint64 encCash, bytes calldata cashPf
    ) external onlyRM returns (uint256 id) {
        euint64 equity = FHE.fromExternal(encEquity, eqPf);
        euint64 bond = FHE.fromExternal(encBond, bdPf);
        euint64 alts = FHE.fromExternal(encAlts, altPf);
        euint64 cash = FHE.fromExternal(encCash, cashPf);
        id = rebalanceCount++;
        rebalances[id] = PortfolioRebalance({
            client: client, equityAllocationBps: equity, bondAllocationBps: bond,
            altAllocationBps: alts, cashAllocationBps: cash,
            rebalancedAt: block.timestamp, approved: false
        });
        FHE.allowThis(rebalances[id].equityAllocationBps);
        FHE.allow(rebalances[id].equityAllocationBps, client);
        FHE.allowThis(rebalances[id].bondAllocationBps);
        FHE.allow(rebalances[id].bondAllocationBps, client);
        FHE.allowThis(rebalances[id].altAllocationBps);
        FHE.allowThis(rebalances[id].cashAllocationBps);
        emit RebalanceProposed(id, client);
    }

    function approveRebalance(uint256 rebalanceId) external {
        require(rebalances[rebalanceId].client == msg.sender, "Not client");
        rebalances[rebalanceId].approved = true;
        emit RebalanceApproved(rebalanceId);
    }

    function chargeAnnualFee(address client) external onlyRM {
        euint64 fee = profiles[client].annualFeeUSD;
        _totalFeesEarned = FHE.add(_totalFeesEarned, fee);
        FHE.allowThis(_totalFeesEarned);
        FHE.allow(fee, client);
        emit FeeCharged(client);
    }

    function allowClientProfile(address client, address viewer) external {
        require(msg.sender == client || isRelationshipManager[msg.sender] || isComplianceOfficer[msg.sender], "Unauthorized");
        FHE.allow(profiles[client].aumUSD, viewer);
        FHE.allow(profiles[client].riskScore, viewer);
        FHE.allow(profiles[client].annualFeeUSD, viewer);
        FHE.allow(profiles[client].unrealizedGainUSD, viewer);
    }

    function allowBankStats(address viewer) external onlyOwner {
        FHE.allow(_totalBankAUM, viewer);
        FHE.allow(_totalFeesEarned, viewer);
    }
}
