// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDecentralizedIdentityKYCVault
/// @notice Self-sovereign identity (SSI) with encrypted KYC attributes,
///         credit scores, and sanctions screening results. Selective disclosure.
contract PrivateDecentralizedIdentityKYCVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum KYCTier { NONE, BASIC, ENHANCED, INSTITUTIONAL }
    enum SanctionStatus { CLEAR, FLAGGED, BLOCKED }

    struct Identity {
        address holder;
        KYCTier tier;
        euint8  creditScore;          // encrypted 0-100
        euint8  amlRiskScore;         // encrypted AML risk 0-100
        euint8  idVerificationScore;  // encrypted ID check 0-100
        euint8  sanctionScore;        // encrypted sanction screening
        euint64 annualIncomeUSD;      // encrypted declared income
        euint64 netWorthUSD;          // encrypted declared net worth
        euint32 jurisdictionCode;     // encrypted country code
        uint256 issuedAt;
        uint256 expiresAt;
        SanctionStatus sanctionStatus;
        bool active;
    }

    struct DisclosureGrant {
        euint8  attributeMask;        // encrypted bitmask of disclosed attributes
        euint64 expiryTimestamp;      // encrypted expiry of disclosure
        bool    active;
    }

    mapping(address => Identity)                       private identities;
    mapping(address => mapping(address => DisclosureGrant)) private disclosures;
    mapping(address => bool) public isKYCProvider;
    mapping(address => bool) public isSanctionsOracle;
    euint64 private _totalIdentitiesIssued;
    euint32 private _totalFlaggedIdentities;

    event IdentityIssued(address indexed holder, KYCTier tier);
    event IdentityRevoked(address indexed holder);
    event DisclosureGranted(address indexed holder, address indexed verifier);
    event SanctionFlagged(address indexed holder);

    constructor() Ownable(msg.sender) {
        _totalIdentitiesIssued  = FHE.asEuint64(0);
        _totalFlaggedIdentities = FHE.asEuint32(0);
        FHE.allowThis(_totalIdentitiesIssued);
        FHE.allowThis(_totalFlaggedIdentities);
        isKYCProvider[msg.sender]    = true;
        isSanctionsOracle[msg.sender]= true;
    }

    function addKYCProvider(address p) external onlyOwner { isKYCProvider[p] = true; }
    function addSanctionsOracle(address o) external onlyOwner { isSanctionsOracle[o] = true; }

    function issueIdentity(
        address holder,
        KYCTier tier,
        externalEuint8  encCredit,    bytes calldata creditProof,
        externalEuint8  encAML,       bytes calldata amlProof,
        externalEuint8  encIDScore,   bytes calldata idProof,
        externalEuint64 encIncome,    bytes calldata incomeProof,
        externalEuint64 encNetWorth,  bytes calldata nwProof,
        externalEuint32 encJurisCode, bytes calldata jurProof,
        uint256 validityDays
    ) external {
        require(isKYCProvider[msg.sender], "Not KYC provider");
        euint8  credit    = FHE.fromExternal(encCredit,    creditProof);
        euint8  aml       = FHE.fromExternal(encAML,       amlProof);
        euint8  idScore   = FHE.fromExternal(encIDScore,   idProof);
        euint64 income    = FHE.fromExternal(encIncome,    incomeProof);
        euint64 netWorth  = FHE.fromExternal(encNetWorth,  nwProof);
        euint32 jurisCode = FHE.fromExternal(encJurisCode, jurProof);

        Identity storage _s0 = identities[holder];
        _s0.holder = holder;
        _s0.tier = tier;
        _s0.creditScore = credit;
        _s0.amlRiskScore = aml;
        _s0.idVerificationScore = idScore;
        _s0.sanctionScore = FHE.asEuint8(0);
        _s0.annualIncomeUSD = income;
        _s0.netWorthUSD = netWorth;
        _s0.jurisdictionCode = jurisCode;
        _s0.issuedAt = block.timestamp;
        _s0.expiresAt = block.timestamp + validityDays * 1 days;
        _s0.sanctionStatus = SanctionStatus.CLEAR;
        _s0.active = true;
        _totalIdentitiesIssued = FHE.add(_totalIdentitiesIssued, FHE.asEuint64(1));

        FHE.allowThis(identities[holder].creditScore);
        FHE.allow(identities[holder].creditScore, holder);
        FHE.allowThis(identities[holder].amlRiskScore);
        FHE.allowThis(identities[holder].idVerificationScore);
        FHE.allow(identities[holder].idVerificationScore, holder);
        FHE.allowThis(identities[holder].sanctionScore);
        FHE.allowThis(identities[holder].annualIncomeUSD);
        FHE.allow(identities[holder].annualIncomeUSD, holder);
        FHE.allowThis(identities[holder].netWorthUSD);
        FHE.allow(identities[holder].netWorthUSD, holder);
        FHE.allowThis(identities[holder].jurisdictionCode);
        FHE.allow(identities[holder].jurisdictionCode, holder);
        FHE.allowThis(_totalIdentitiesIssued);
        emit IdentityIssued(holder, tier);
    }

    function grantDisclosure(
        address verifier,
        externalEuint8  encMask,   bytes calldata maskProof,
        externalEuint64 encExpiry, bytes calldata expProof
    ) external {
        require(identities[msg.sender].active, "No identity");
        euint8  mask   = FHE.fromExternal(encMask,   maskProof);
        euint64 expiry = FHE.fromExternal(encExpiry, expProof);

        disclosures[msg.sender][verifier] = DisclosureGrant({
            attributeMask: mask,
            expiryTimestamp: expiry,
            active: true
        });
        FHE.allowThis(disclosures[msg.sender][verifier].attributeMask);
        FHE.allow(disclosures[msg.sender][verifier].attributeMask, verifier);
        FHE.allowThis(disclosures[msg.sender][verifier].expiryTimestamp);
        FHE.allow(disclosures[msg.sender][verifier].expiryTimestamp, verifier);

        // Allow verifier to read disclosed attributes
        if (FHE.isInitialized(mask)) {
            FHE.allow(identities[msg.sender].creditScore, verifier);
            FHE.allow(identities[msg.sender].jurisdictionCode, verifier);
        }
        emit DisclosureGranted(msg.sender, verifier);
    }

    function screenSanctions(
        address holder,
        externalEuint8 encSanctionScore, bytes calldata proof
    ) external {
        require(isSanctionsOracle[msg.sender], "Not oracle");
        euint8 score = FHE.fromExternal(encSanctionScore, proof);
        identities[holder].sanctionScore = score;
        ebool isFlagged = FHE.gt(score, FHE.asEuint8(50));
        if (FHE.isInitialized(isFlagged)) {
            identities[holder].sanctionStatus = SanctionStatus.FLAGGED;
            _totalFlaggedIdentities = FHE.add(_totalFlaggedIdentities, FHE.asEuint32(1));
            FHE.allowThis(_totalFlaggedIdentities);
            emit SanctionFlagged(holder);
        }
        FHE.allowThis(identities[holder].sanctionScore);
        FHE.allow(identities[holder].sanctionScore, msg.sender);
    }

    function revokeIdentity(address holder) external {
        require(isKYCProvider[msg.sender] || msg.sender == owner(), "Unauthorized");
        identities[holder].active = false;
        emit IdentityRevoked(holder);
    }

    function allowSystemView(address viewer) external onlyOwner {
        FHE.allow(_totalIdentitiesIssued, viewer);
        FHE.allow(_totalFlaggedIdentities, viewer);
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