// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFloodInsuranceRiskPool
/// @notice Encrypted community flood insurance risk pool: hidden property flood zone scores,
///         confidential premium calculations, private catastrophe deductibles, and encrypted
///         government reinsurance backstop utilization.
contract PrivateFloodInsuranceRiskPool is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum FloodZone { ZoneA, ZoneAE, ZoneX, ZoneV, ZoneAO }
    enum ClaimStatus { Filed, Adjusted, Approved, PartialPay, Denied }

    struct PolicyHolder {
        address policyHolder;
        FloodZone floodZone;
        string propertyRef;
        euint64 insuredValueUSD;       // encrypted property insured value
        euint64 annualPremiumUSD;      // encrypted premium
        euint64 deductibleUSD;         // encrypted deductible
        euint16 floodRiskScoreBps;     // encrypted risk score
        euint64 totalPremiumsPaidUSD;  // encrypted total premiums paid
        bool active;
        uint256 policyStart;
        uint256 policyEnd;
    }

    struct FloodClaim {
        uint256 policyId;
        address policyholder;
        euint64 claimedDamageUSD;      // encrypted claimed damage
        euint64 approvedPayoutUSD;     // encrypted approved payout
        euint64 govBackstopUSD;        // encrypted government backstop portion
        ClaimStatus status;
        uint256 filedAt;
    }

    mapping(uint256 => PolicyHolder) private policies;
    mapping(uint256 => FloodClaim) private claims;
    mapping(address => bool) public isFloodAdjuster;

    uint256 public policyCount;
    uint256 public claimCount;
    euint64 private _totalPremiumsUSD;
    euint64 private _totalClaimsUSD;
    euint64 private _totalGovBackstopUSD;

    event PolicyIssued(uint256 indexed id, FloodZone zone);
    event ClaimFiled(uint256 indexed claimId, uint256 policyId);
    event ClaimSettled(uint256 indexed claimId, uint256 settledAt);

    modifier onlyFloodAdjuster() {
        require(isFloodAdjuster[msg.sender] || msg.sender == owner(), "Not flood adjuster");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPremiumsUSD = FHE.asEuint64(0);
        _totalClaimsUSD = FHE.asEuint64(0);
        _totalGovBackstopUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsUSD);
        FHE.allowThis(_totalClaimsUSD);
        FHE.allowThis(_totalGovBackstopUSD);
        isFloodAdjuster[msg.sender] = true;
    }

    function addFloodAdjuster(address a) external onlyOwner { isFloodAdjuster[a] = true; }

    function issuePolicy(
        FloodZone zone, string calldata propertyRef,
        externalEuint64 encInsuredValue, bytes calldata ivProof,
        externalEuint64 encPremium, bytes calldata prProof,
        externalEuint64 encDeductible, bytes calldata dProof,
        externalEuint16 encRiskScore, bytes calldata rsProof,
        uint256 termDays
    ) external returns (uint256 id) {
        euint64 insuredValue = FHE.fromExternal(encInsuredValue, ivProof);
        euint64 premium = FHE.fromExternal(encPremium, prProof);
        euint64 deductible = FHE.fromExternal(encDeductible, dProof);
        euint16 riskScore = FHE.fromExternal(encRiskScore, rsProof);
        id = policyCount++;
        policies[id].policyHolder = msg.sender;
        policies[id].floodZone = zone;
        policies[id].propertyRef = propertyRef;
        policies[id].insuredValueUSD = insuredValue;
        policies[id].annualPremiumUSD = premium;
        policies[id].deductibleUSD = deductible;
        policies[id].floodRiskScoreBps = riskScore;
        policies[id].totalPremiumsPaidUSD = FHE.asEuint64(0);
        policies[id].active = true;
        policies[id].policyStart = block.timestamp;
        policies[id].policyEnd = block.timestamp + termDays * 1 days;
        FHE.allowThis(policies[id].insuredValueUSD); FHE.allow(policies[id].insuredValueUSD, msg.sender);
        FHE.allowThis(policies[id].annualPremiumUSD); FHE.allow(policies[id].annualPremiumUSD, msg.sender);
        FHE.allowThis(policies[id].deductibleUSD); FHE.allow(policies[id].deductibleUSD, msg.sender);
        FHE.allowThis(policies[id].floodRiskScoreBps);
        FHE.allowThis(policies[id].totalPremiumsPaidUSD); FHE.allow(policies[id].totalPremiumsPaidUSD, msg.sender);
        emit PolicyIssued(id, zone);
    }

    function payPremium(uint256 policyId) external nonReentrant {
        PolicyHolder storage p = policies[policyId];
        require(msg.sender == p.policyHolder && p.active, "Not authorized");
        p.totalPremiumsPaidUSD = FHE.add(p.totalPremiumsPaidUSD, p.annualPremiumUSD);
        _totalPremiumsUSD = FHE.add(_totalPremiumsUSD, p.annualPremiumUSD);
        FHE.allowThis(p.totalPremiumsPaidUSD); FHE.allow(p.totalPremiumsPaidUSD, msg.sender);
        FHE.allowThis(_totalPremiumsUSD);
    }

    function fileClaim(
        uint256 policyId,
        externalEuint64 encDamage, bytes calldata proof
    ) external nonReentrant returns (uint256 claimId) {
        PolicyHolder storage p = policies[policyId];
        require(msg.sender == p.policyHolder && p.active, "Not authorized");
        euint64 damage = FHE.fromExternal(encDamage, proof);
        claimId = claimCount++;
        claims[claimId] = FloodClaim({
            policyId: policyId, policyholder: msg.sender, claimedDamageUSD: damage,
            approvedPayoutUSD: FHE.asEuint64(0), govBackstopUSD: FHE.asEuint64(0),
            status: ClaimStatus.Filed, filedAt: block.timestamp
        });
        FHE.allowThis(claims[claimId].claimedDamageUSD); FHE.allow(claims[claimId].claimedDamageUSD, msg.sender);
        FHE.allowThis(claims[claimId].approvedPayoutUSD); FHE.allow(claims[claimId].approvedPayoutUSD, msg.sender);
        FHE.allowThis(claims[claimId].govBackstopUSD);
        emit ClaimFiled(claimId, policyId);
    }

    function settleClaim(
        uint256 claimId,
        externalEuint64 encApproved, bytes calldata apProof,
        externalEuint64 encGovBackstop, bytes calldata gbProof
    ) external onlyFloodAdjuster nonReentrant {
        FloodClaim storage c = claims[claimId];
        PolicyHolder storage p = policies[c.policyId];
        euint64 approved = FHE.fromExternal(encApproved, apProof);
        euint64 govBackstop = FHE.fromExternal(encGovBackstop, gbProof);
        c.approvedPayoutUSD = approved;
        c.govBackstopUSD = govBackstop;
        c.status = ClaimStatus.Approved;
        _totalClaimsUSD = FHE.add(_totalClaimsUSD, approved);
        _totalGovBackstopUSD = FHE.add(_totalGovBackstopUSD, govBackstop);
        FHE.allowThis(c.approvedPayoutUSD); FHE.allow(c.approvedPayoutUSD, c.policyholder);
        FHE.allowThis(c.govBackstopUSD);
        FHE.allowThis(_totalClaimsUSD);
        FHE.allowThis(_totalGovBackstopUSD);
        emit ClaimSettled(claimId, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsUSD, viewer);
        FHE.allow(_totalClaimsUSD, viewer);
        FHE.allow(_totalGovBackstopUSD, viewer);
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