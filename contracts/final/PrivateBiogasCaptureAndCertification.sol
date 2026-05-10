// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateBiogasCaptureAndCertification
/// @notice Encrypted biogas capture facility: hidden methane capture volumes, confidential
///         renewable natural gas certification values, private tipping fee arrangements,
///         and encrypted carbon credit issuance for landfill gas projects.
contract PrivateBiogasCaptureAndCertification is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum FeedstockSource { LandfillGas, AnaerobicDigestion, AgriWaste, WastewaterSludge, FoodWaste }
    enum CertificationBody { RNG_Coalition, CalARM, I_REC, GreenE, REC_Registry }

    struct BiogasFacility {
        address operator;
        FeedstockSource feedstockSource;
        string facilityRef;
        string state;
        euint64 dailyCaptureMMBtu;     // encrypted daily capture (MMBtu)
        euint64 annualRNGCertValue;    // encrypted RNG certificate value
        euint64 tippingFeeUSD;         // encrypted tipping fee
        euint64 carbonCreditsIssued;   // encrypted carbon credits (tCO2)
        euint16 methaneDestructionBps; // encrypted methane destruction efficiency
        euint64 totalRevenueUSD;       // encrypted total revenue
        CertificationBody certBody;
        bool active;
    }

    mapping(uint256 => BiogasFacility) private facilities;
    mapping(address => bool) public isEPAAuthority;

    uint256 public facilityCount;
    euint64 private _totalRNGProductionMMBtu;
    euint64 private _totalCarbonCredits;

    event FacilityRegistered(uint256 indexed id, FeedstockSource source);
    event RNGCertified(uint256 indexed id, uint256 certifiedAt);

    modifier onlyEPAAuthority() {
        require(isEPAAuthority[msg.sender] || msg.sender == owner(), "Not EPA authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRNGProductionMMBtu = FHE.asEuint64(0);
        _totalCarbonCredits = FHE.asEuint64(0);
        FHE.allowThis(_totalRNGProductionMMBtu);
        FHE.allowThis(_totalCarbonCredits);
        isEPAAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addEPAAuthority(address a) external onlyOwner { isEPAAuthority[a] = true; }

    function registerFacility(
        FeedstockSource source, string calldata facilityRef, string calldata state,
        externalEuint64 encDailyCapture, bytes calldata dcProof,
        externalEuint64 encTippingFee, bytes calldata tfProof,
        externalEuint16 encMethDestruction, bytes calldata mdProof,
        CertificationBody certBody
    ) external whenNotPaused returns (uint256 id) {
        euint64 dailyCapture = FHE.fromExternal(encDailyCapture, dcProof);
        euint64 tippingFee = FHE.fromExternal(encTippingFee, tfProof);
        euint16 methDestruction = FHE.fromExternal(encMethDestruction, mdProof);
        id = facilityCount++;
        BiogasFacility storage _s0 = facilities[id];
        _s0.operator = msg.sender;
        _s0.feedstockSource = source;
        _s0.facilityRef = facilityRef;
        _s0.state = state;
        _s0.dailyCaptureMMBtu = dailyCapture;
        _s0.annualRNGCertValue = FHE.asEuint64(0);
        _s0.tippingFeeUSD = tippingFee;
        _s0.carbonCreditsIssued = FHE.asEuint64(0);
        _s0.methaneDestructionBps = methDestruction;
        _s0.totalRevenueUSD = FHE.asEuint64(0);
        _s0.certBody = certBody;
        _s0.active = true;
        FHE.allowThis(facilities[id].dailyCaptureMMBtu); FHE.allow(facilities[id].dailyCaptureMMBtu, msg.sender);
        FHE.allowThis(facilities[id].annualRNGCertValue); FHE.allow(facilities[id].annualRNGCertValue, msg.sender);
        FHE.allowThis(facilities[id].tippingFeeUSD); FHE.allow(facilities[id].tippingFeeUSD, msg.sender);
        FHE.allowThis(facilities[id].carbonCreditsIssued); FHE.allow(facilities[id].carbonCreditsIssued, msg.sender);
        FHE.allowThis(facilities[id].methaneDestructionBps);
        FHE.allowThis(facilities[id].totalRevenueUSD); FHE.allow(facilities[id].totalRevenueUSD, msg.sender);
        emit FacilityRegistered(id, source);
    }

    function certifyRNG(
        uint256 facilityId,
        externalEuint64 encRNGCertValue, bytes calldata rcvProof,
        externalEuint64 encCarbonCredits, bytes calldata ccProof
    ) external onlyEPAAuthority nonReentrant {
        BiogasFacility storage f = facilities[facilityId];
        euint64 rngCertValue = FHE.fromExternal(encRNGCertValue, rcvProof);
        euint64 carbonCredits = FHE.fromExternal(encCarbonCredits, ccProof);
        f.annualRNGCertValue = rngCertValue;
        f.carbonCreditsIssued = FHE.add(f.carbonCreditsIssued, carbonCredits);
        f.totalRevenueUSD = FHE.add(f.totalRevenueUSD, rngCertValue);
        _totalRNGProductionMMBtu = FHE.add(_totalRNGProductionMMBtu, f.dailyCaptureMMBtu);
        _totalCarbonCredits = FHE.add(_totalCarbonCredits, carbonCredits);
        FHE.allowThis(f.annualRNGCertValue); FHE.allow(f.annualRNGCertValue, f.operator);
        FHE.allowThis(f.carbonCreditsIssued); FHE.allow(f.carbonCreditsIssued, f.operator);
        FHE.allowThis(f.totalRevenueUSD); FHE.allow(f.totalRevenueUSD, f.operator);
        FHE.allowThis(_totalRNGProductionMMBtu);
        FHE.allowThis(_totalCarbonCredits);
        emit RNGCertified(facilityId, block.timestamp);
    }

    function allowSystemStats(address viewer) external onlyOwner {
        FHE.allow(_totalRNGProductionMMBtu, viewer);
        FHE.allow(_totalCarbonCredits, viewer);
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