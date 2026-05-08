// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedCarbonCreditForwardContract
/// @notice Forward contracts for voluntary carbon credits with encrypted
///         delivery obligations, carbon quality scores (Verra/Gold Standard),
///         and counterparty credit risk metrics.
contract EncryptedCarbonCreditForwardContract is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum CarbonStandard { Verra_VCS, GoldStandard, ACR, CAR, Plan_Vivo, Puro_Earth }
    enum ProjectType { REDD_Plus, ReforestationAfforestation, SoilCarbon, BioChar, DirectAirCapture, CookStoves, Methane }
    enum ForwardStatus { Negotiating, Executed, DeliveryPeriod, Delivered, Defaulted, Settled }

    struct CarbonForward {
        uint256 forwardId;
        address buyer;
        address seller;
        CarbonStandard standard;
        ProjectType projectType;
        euint64 contractTonnesCO2;      // encrypted contracted volume
        euint64 priceUSDPerTonne;       // encrypted agreed price
        euint64 totalContractValueUSD;  // encrypted total value
        euint32 qualityScoreBps;        // encrypted quality rating
        euint32 additionalityBps;       // encrypted additionality rating
        euint32 permanenceBps;          // encrypted permanence risk rating
        euint64 collateralPostedUSD;    // encrypted margin posted by seller
        euint64 deliveredTonnes;        // encrypted tonnes delivered so far
        ForwardStatus status;
        uint256 executionDate;
        uint256 deliveryDate;
    }

    struct VerificationStatement {
        uint256 forwardId;
        string verifierId;
        euint64 verifiedTonnesCO2;       // encrypted verified volume
        euint32 verificationScoreBps;    // encrypted verification confidence
        bool accepted;
        uint256 verifiedAt;
    }

    mapping(uint256 => CarbonForward) private forwards;
    mapping(uint256 => VerificationStatement[]) private verifications;
    mapping(address => bool) public isCarbonBroker;
    mapping(address => bool) public isVerifier;

    uint256 public forwardCount;
    euint64 private _totalContractedTonnes;
    euint64 private _totalDeliveredTonnes;
    euint64 private _totalContractValue;

    event ForwardExecuted(uint256 indexed forwardId, address buyer, address seller);
    event VerificationSubmitted(uint256 indexed forwardId, uint256 verIdx);
    event ForwardDelivered(uint256 indexed forwardId);
    event ForwardDefaulted(uint256 indexed forwardId);

    modifier onlyBroker() {
        require(isCarbonBroker[msg.sender] || msg.sender == owner(), "Not carbon broker");
        _;
    }
    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalContractedTonnes = FHE.asEuint64(0);
        _totalDeliveredTonnes = FHE.asEuint64(0);
        _totalContractValue = FHE.asEuint64(0);
        FHE.allowThis(_totalContractedTonnes);
        FHE.allowThis(_totalDeliveredTonnes);
        FHE.allowThis(_totalContractValue);
        isCarbonBroker[msg.sender] = true;
        isVerifier[msg.sender] = true;
    }

    function addBroker(address b) external onlyOwner { isCarbonBroker[b] = true; }
    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }

    function executeForward(
        address buyer,
        address seller,
        CarbonStandard standard,
        ProjectType projectType,
        externalEuint64 encTonnes, bytes calldata tonnesProof,
        externalEuint64 encPrice, bytes calldata priceProof,
        externalEuint32 encQuality, bytes calldata qualProof,
        externalEuint32 encAdditionality, bytes calldata addProof,
        externalEuint32 encPermanence, bytes calldata permProof,
        externalEuint64 encCollateral, bytes calldata collProof,
        uint256 deliveryDate
    ) external onlyBroker returns (uint256 forwardId) {
        euint64 tonnes = FHE.fromExternal(encTonnes, tonnesProof);
        euint64 price = FHE.fromExternal(encPrice, priceProof);
        euint64 totalValue = FHE.mul(tonnes, price);
        forwardId = forwardCount++;
        CarbonForward storage f = forwards[forwardId];
        f.forwardId = forwardId;
        f.buyer = buyer;
        f.seller = seller;
        f.standard = standard;
        f.projectType = projectType;
        f.contractTonnesCO2 = tonnes;
        f.priceUSDPerTonne = price;
        f.totalContractValueUSD = totalValue;
        f.qualityScoreBps = FHE.fromExternal(encQuality, qualProof);
        f.additionalityBps = FHE.fromExternal(encAdditionality, addProof);
        f.permanenceBps = FHE.fromExternal(encPermanence, permProof);
        f.collateralPostedUSD = FHE.fromExternal(encCollateral, collProof);
        f.deliveredTonnes = FHE.asEuint64(0);
        f.status = ForwardStatus.Executed;
        f.executionDate = block.timestamp;
        f.deliveryDate = deliveryDate;
        _totalContractedTonnes = FHE.add(_totalContractedTonnes, tonnes);
        _totalContractValue = FHE.add(_totalContractValue, totalValue);
        FHE.allowThis(f.contractTonnesCO2); FHE.allow(f.contractTonnesCO2, buyer); FHE.allow(f.contractTonnesCO2, seller);
        FHE.allowThis(f.priceUSDPerTonne); FHE.allow(f.priceUSDPerTonne, buyer); FHE.allow(f.priceUSDPerTonne, seller);
        FHE.allowThis(f.totalContractValueUSD);
        FHE.allowThis(f.qualityScoreBps); FHE.allowThis(f.additionalityBps); FHE.allowThis(f.permanenceBps);
        FHE.allowThis(f.collateralPostedUSD); FHE.allowThis(f.deliveredTonnes);
        FHE.allowThis(_totalContractedTonnes); FHE.allowThis(_totalContractValue);
        emit ForwardExecuted(forwardId, buyer, seller);
    }

    function submitVerification(
        uint256 forwardId,
        string calldata verifierId,
        externalEuint64 encVerifiedTonnes, bytes calldata tonnesProof,
        externalEuint32 encVerifScore, bytes calldata scoreProof
    ) external onlyVerifier {
        CarbonForward storage f = forwards[forwardId];
        require(f.status == ForwardStatus.Executed || f.status == ForwardStatus.DeliveryPeriod, "Wrong status");
        euint64 verifiedTonnes = FHE.fromExternal(encVerifiedTonnes, tonnesProof);
        euint32 verifScore = FHE.fromExternal(encVerifScore, scoreProof);
        uint256 vIdx = verifications[forwardId].length;
        verifications[forwardId].push(VerificationStatement({
            forwardId: forwardId,
            verifierId: verifierId,
            verifiedTonnesCO2: verifiedTonnes,
            verificationScoreBps: verifScore,
            accepted: false,
            verifiedAt: block.timestamp
        }));
        FHE.allowThis(verifications[forwardId][vIdx].verifiedTonnesCO2);
        FHE.allow(verifications[forwardId][vIdx].verifiedTonnesCO2, f.buyer);
        FHE.allow(verifications[forwardId][vIdx].verifiedTonnesCO2, f.seller);
        FHE.allowThis(verifications[forwardId][vIdx].verificationScoreBps);
        emit VerificationSubmitted(forwardId, vIdx);
    }

    function acceptVerificationAndDeliver(
        uint256 forwardId,
        uint256 verIdx
    ) external onlyBroker {
        CarbonForward storage f = forwards[forwardId];
        VerificationStatement storage v = verifications[forwardId][verIdx];
        v.accepted = true;
        f.deliveredTonnes = FHE.add(f.deliveredTonnes, v.verifiedTonnesCO2);
        _totalDeliveredTonnes = FHE.add(_totalDeliveredTonnes, v.verifiedTonnesCO2);
        // Check if fully delivered
        ebool fullyDelivered = FHE.ge(f.deliveredTonnes, f.contractTonnesCO2);
        if (FHE.isInitialized(fullyDelivered)) {
            f.status = ForwardStatus.Delivered;
            emit ForwardDelivered(forwardId);
        }
        FHE.allowThis(f.deliveredTonnes); FHE.allow(f.deliveredTonnes, f.buyer);
        FHE.allowThis(_totalDeliveredTonnes);
    }

    function declareDefault(uint256 forwardId) external onlyBroker {
        require(block.timestamp > forwards[forwardId].deliveryDate, "Not past delivery");
        require(forwards[forwardId].status != ForwardStatus.Delivered, "Already delivered");
        forwards[forwardId].status = ForwardStatus.Defaulted;
        emit ForwardDefaulted(forwardId);
    }

    function allowCarbonMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalContractedTonnes, viewer);
        FHE.allow(_totalDeliveredTonnes, viewer);
        FHE.allow(_totalContractValue, viewer);
    }
}
