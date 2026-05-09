// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateInternationalRemittance
/// @notice Cross-border remittance with encrypted sender/receiver amounts,
///         encrypted FX rate, encrypted compliance score, and AML gating.
contract PrivateInternationalRemittance is ZamaEthereumConfig, Ownable {
    enum RemittanceStatus { Pending, ComplianceReview, Processed, Rejected, Reversed }

    struct RemittanceOrder {
        address sender;
        string recipientCountry;
        string recipientBankCode;    // plaintext bank routing (not sensitive)
        euint64 senderAmountUSD;     // encrypted send amount
        euint64 recipientAmount;     // encrypted amount after FX
        euint64 fxRateMicroUSD;      // encrypted FX rate applied
        euint64 feesChargedUSD;      // encrypted fees
        euint8 complianceScore;      // encrypted AML compliance score
        RemittanceStatus status;
        uint256 createdAt;
        uint256 processedAt;
    }

    mapping(uint256 => RemittanceOrder) private orders;
    mapping(address => euint64) private _senderVolume;     // encrypted cumulative sent
    mapping(address => euint8) private _kycLevel;           // encrypted KYC level
    mapping(address => bool) public isComplianceOfficer;
    uint256 public orderCount;
    euint64 private _totalVolume;
    euint64 private _totalFees;
    euint8 private _minComplianceScore;   // encrypted minimum score to process

    event OrderCreated(uint256 indexed id, address sender, string destCountry);
    event OrderProcessed(uint256 indexed id);
    event OrderRejected(uint256 indexed id, string reason);
    event OrderReversed(uint256 indexed id);

    constructor(
        externalEuint8 encMinScore, bytes memory proof
    ) Ownable(msg.sender) {
        _minComplianceScore = FHE.fromExternal(encMinScore, proof);
        _totalVolume = FHE.asEuint64(0);
        _totalFees = FHE.asEuint64(0);
        FHE.allowThis(_minComplianceScore);
        FHE.allowThis(_totalVolume);
        FHE.allowThis(_totalFees);
        isComplianceOfficer[msg.sender] = true;
    }

    function addComplianceOfficer(address co) external onlyOwner { isComplianceOfficer[co] = true; }

    function setKYCLevel(address user, externalEuint8 encLevel, bytes calldata proof) external {
        require(isComplianceOfficer[msg.sender], "Not officer");
        euint8 level = FHE.fromExternal(encLevel, proof);
        _kycLevel[user] = level;
        FHE.allowThis(_kycLevel[user]);
        FHE.allow(_kycLevel[user], user);
    }

    function createOrder(
        string calldata recipientCountry, string calldata recipientBankCode,
        externalEuint64 encSendAmt, bytes calldata saProof,
        externalEuint64 encFXRate, bytes calldata fxProof,
        externalEuint64 encFees, bytes calldata fProof,
        externalEuint8 encComplianceScore, bytes calldata csProof
    ) external returns (uint256 id) {
        euint64 sendAmt = FHE.fromExternal(encSendAmt, saProof);
        euint64 fxRate = FHE.fromExternal(encFXRate, fxProof);
        euint64 fees = FHE.fromExternal(encFees, fProof);
        euint8 compScore = FHE.fromExternal(encComplianceScore, csProof);
        euint64 netAfterFees = FHE.sub(sendAmt, fees);
        euint64 recipientAmt = FHE.mul(netAfterFees, fxRate); // simplified
        id = orderCount++;
        orders[id].sender = msg.sender;
        orders[id].recipientCountry = recipientCountry;
        orders[id].recipientBankCode = recipientBankCode;
        orders[id].senderAmountUSD = sendAmt;
        orders[id].recipientAmount = recipientAmt;
        orders[id].fxRateMicroUSD = fxRate;
        orders[id].feesChargedUSD = fees;
        orders[id].complianceScore = compScore;
        orders[id].status = RemittanceStatus.Pending;
        orders[id].createdAt = block.timestamp;
        orders[id].processedAt = 0;
        FHE.allowThis(orders[id].senderAmountUSD);
        FHE.allow(orders[id].senderAmountUSD, msg.sender);
        FHE.allowThis(orders[id].recipientAmount);
        FHE.allow(orders[id].recipientAmount, msg.sender);
        FHE.allowThis(orders[id].fxRateMicroUSD);
        FHE.allowThis(orders[id].feesChargedUSD);
        FHE.allowThis(orders[id].complianceScore);
        if (!FHE.isInitialized(_senderVolume[msg.sender])) {
            _senderVolume[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(_senderVolume[msg.sender]);
        }
        emit OrderCreated(id, msg.sender, recipientCountry);
    }

    function processOrder(uint256 orderId) external {
        require(isComplianceOfficer[msg.sender], "Not officer");
        RemittanceOrder storage o = orders[orderId];
        require(o.status == RemittanceStatus.Pending, "Not pending");
        // Check compliance score
        ebool passesCompliance = FHE.ge(o.complianceScore, _minComplianceScore);
        if (FHE.isInitialized(passesCompliance)) {
            o.status = RemittanceStatus.Processed;
            o.processedAt = block.timestamp;
            _senderVolume[o.sender] = FHE.add(_senderVolume[o.sender], o.senderAmountUSD);
            _totalVolume = FHE.add(_totalVolume, o.senderAmountUSD);
            _totalFees = FHE.add(_totalFees, o.feesChargedUSD);
            FHE.allowThis(_senderVolume[o.sender]);
            FHE.allowThis(_totalVolume);
            FHE.allowThis(_totalFees);
            FHE.allow(o.recipientAmount, o.sender);
            emit OrderProcessed(orderId);
        } else {
            o.status = RemittanceStatus.Rejected;
            emit OrderRejected(orderId, "Compliance failure");
        }
    }

    function reverseOrder(uint256 orderId) external {
        require(isComplianceOfficer[msg.sender], "Not officer");
        RemittanceOrder storage o = orders[orderId];
        require(o.status == RemittanceStatus.Processed, "Not processed");
        o.status = RemittanceStatus.Reversed;
        _totalVolume = FHE.sub(_totalVolume, o.senderAmountUSD);
        FHE.allowThis(_totalVolume);
        FHE.allow(o.senderAmountUSD, o.sender);
        emit OrderReversed(orderId);
    }

    function allowOrderDetails(uint256 orderId, address viewer) external {
        RemittanceOrder storage o = orders[orderId];
        require(msg.sender == o.sender || isComplianceOfficer[msg.sender], "Unauthorized");
        FHE.allow(o.senderAmountUSD, viewer);
        FHE.allow(o.recipientAmount, viewer);
        FHE.allow(o.feesChargedUSD, viewer);
    }

    function allowVolumeStats(address viewer) external onlyOwner {
        FHE.allow(_totalVolume, viewer);
        FHE.allow(_totalFees, viewer);
    }
}
