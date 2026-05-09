// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedPrivateBankWealth
/// @notice Swiss private banking wealth management with encrypted AUM,
///         fee schedules, discretionary mandates, and tax optimization strategies.
contract EncryptedPrivateBankWealth is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum MandateType { DISCRETIONARY, ADVISORY, EXECUTION_ONLY }
    enum RiskProfile { CAPITAL_PRESERVATION, CONSERVATIVE, BALANCED, GROWTH, AGGRESSIVE }

    struct ClientMandate {
        address client;
        MandateType mandateType;
        RiskProfile riskProfile;
        euint64 aumUSD;                // encrypted AUM
        euint64 annualFeeUSD;          // encrypted management fee
        euint64 performanceFeeUSD;     // encrypted performance fee earned
        euint64 ytdReturnBps;          // encrypted year-to-date return
        euint64 benchmarkReturnBps;    // encrypted benchmark
        euint64 alphaGeneratedBps;     // encrypted alpha
        euint32 clientSince;           // encrypted year onboarded
        euint8  riskToleranceScore;    // encrypted 0-100
        bool active;
        bool taxOptimized;
    }

    mapping(uint256 => ClientMandate) private mandates;
    mapping(address => uint256) private clientToMandate;
    mapping(address => bool) public isRelationshipManager;
    uint256 public mandateCount;
    euint64 private _totalAUM;
    euint64 private _totalFeesEarned;

    event MandateCreated(uint256 indexed mandateId, address client);
    event AUMUpdated(uint256 indexed mandateId);
    event FeeCharged(uint256 indexed mandateId);

    constructor() Ownable(msg.sender) {
        _totalAUM = FHE.asEuint64(0);
        _totalFeesEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalAUM);
        FHE.allowThis(_totalFeesEarned);
        isRelationshipManager[msg.sender] = true;
    }

    function addRM(address rm) external onlyOwner { isRelationshipManager[rm] = true; }

    function createMandate(
        address client,
        MandateType mType,
        RiskProfile rProfile,
        externalEuint64 encAUM,     bytes calldata aumProof,
        externalEuint64 encFee,     bytes calldata feeProof,
        externalEuint8  encRisk,    bytes calldata riskProof
    ) external returns (uint256 mandateId) {
        require(isRelationshipManager[msg.sender], "Not RM");
        euint64 aum  = FHE.fromExternal(encAUM, aumProof);
        euint64 fee  = FHE.fromExternal(encFee, feeProof);
        euint8  risk = FHE.fromExternal(encRisk, riskProof);
        mandateId = mandateCount++;
        ClientMandate storage _s0 = mandates[mandateId];
        _s0.client = client;
        _s0.mandateType = mType;
        _s0.riskProfile = rProfile;
        _s0.aumUSD = aum;
        _s0.annualFeeUSD = fee;
        _s0.performanceFeeUSD = FHE.asEuint64(0);
        _s0.ytdReturnBps = FHE.asEuint64(0);
        _s0.benchmarkReturnBps = FHE.asEuint64(0);
        _s0.alphaGeneratedBps = FHE.asEuint64(0);
        _s0.clientSince = FHE.asEuint32(0);
        _s0.riskToleranceScore = risk;
        _s0.active = true;
        _s0.taxOptimized = false;
        clientToMandate[client] = mandateId;
        _totalAUM = FHE.add(_totalAUM, aum);
        FHE.allowThis(mandates[mandateId].aumUSD);
        FHE.allow(mandates[mandateId].aumUSD, client);
        FHE.allowThis(mandates[mandateId].annualFeeUSD);
        FHE.allow(mandates[mandateId].annualFeeUSD, client);
        FHE.allowThis(mandates[mandateId].performanceFeeUSD);
        FHE.allowThis(mandates[mandateId].ytdReturnBps);
        FHE.allow(mandates[mandateId].ytdReturnBps, client);
        FHE.allowThis(mandates[mandateId].alphaGeneratedBps);
        FHE.allowThis(mandates[mandateId].riskToleranceScore);
        FHE.allowThis(_totalAUM);
        emit MandateCreated(mandateId, client);
    }

    function updateAUM(uint256 mandateId, externalEuint64 encNewAUM, bytes calldata proof) external {
        require(isRelationshipManager[msg.sender], "Not RM");
        euint64 oldAUM = mandates[mandateId].aumUSD;
        euint64 newAUM = FHE.fromExternal(encNewAUM, proof);
        _totalAUM = FHE.sub(_totalAUM, oldAUM);
        _totalAUM = FHE.add(_totalAUM, newAUM);
        mandates[mandateId].aumUSD = newAUM;
        FHE.allowThis(mandates[mandateId].aumUSD);
        FHE.allow(mandates[mandateId].aumUSD, mandates[mandateId].client);
        FHE.allowThis(_totalAUM);
        emit AUMUpdated(mandateId);
    }

    function chargeAnnualFee(uint256 mandateId) external {
        require(isRelationshipManager[msg.sender], "Not RM");
        mandates[mandateId].aumUSD = FHE.sub(mandates[mandateId].aumUSD, mandates[mandateId].annualFeeUSD);
        _totalFeesEarned = FHE.add(_totalFeesEarned, mandates[mandateId].annualFeeUSD);
        FHE.allowThis(mandates[mandateId].aumUSD);
        FHE.allowThis(_totalFeesEarned);
        emit FeeCharged(mandateId);
    }

    function allowBankView(address viewer) external onlyOwner {
        FHE.allow(_totalAUM, viewer);
        FHE.allow(_totalFeesEarned, viewer);
    }
}
