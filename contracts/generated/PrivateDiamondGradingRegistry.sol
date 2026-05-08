// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateDiamondGradingRegistry
/// @notice Diamond grading registry: encrypted 4C scores (cut, color, clarity, carat),
///         encrypted appraisal values, and provenance chain from mine to retailer.
contract PrivateDiamondGradingRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum DiamondOrigin { Botswana, SouthAfrica, Russia, Canada, Australia, Synthetic }
    enum TradingStatus { Unregistered, Graded, Listed, Sold, Insured }

    struct DiamondRecord {
        string certificateId;           // GIA/AGS certificate number
        DiamondOrigin origin;
        euint32 caratWeight;            // encrypted carat x1000 (e.g. 1500 = 1.5ct)
        euint8 cutGrade;                // encrypted 0-10 grade
        euint8 colorGrade;              // encrypted D(0)-Z(23) scale
        euint8 clarityGrade;            // encrypted FL(0)-I3(10) scale
        euint64 appraisalValueUSD;      // encrypted appraised value
        euint64 askingPriceUSD;         // encrypted asking price if listed
        address currentOwner;
        TradingStatus status;
        uint256 gradedAt;
    }

    struct TransferRecord {
        uint256 diamondId;
        address from;
        address to;
        euint64 transactionPriceUSD;    // encrypted transfer price
        uint256 timestamp;
    }

    mapping(uint256 => DiamondRecord) private diamonds;
    mapping(uint256 => TransferRecord[]) private transferHistory;
    mapping(string => uint256) private certToId;
    mapping(address => bool) public isGrader;
    mapping(address => bool) public isRegisteredDealer;

    uint256 public diamondCount;
    euint64 private _totalMarketValueUSD;
    euint64 private _totalVolumeUSD;

    event DiamondRegistered(uint256 indexed id, string certId, DiamondOrigin origin);
    event DiamondListed(uint256 indexed id);
    event DiamondTransferred(uint256 indexed id, address from, address to);

    modifier onlyGrader() {
        require(isGrader[msg.sender] || msg.sender == owner(), "Not grader");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalMarketValueUSD = FHE.asEuint64(0);
        _totalVolumeUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketValueUSD);
        FHE.allowThis(_totalVolumeUSD);
        isGrader[msg.sender] = true;
    }

    function addGrader(address g) external onlyOwner { isGrader[g] = true; }
    function addDealer(address d) external onlyOwner { isRegisteredDealer[d] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerDiamond(
        string calldata certId,
        DiamondOrigin origin,
        address initialOwner,
        externalEuint32 encCarat, bytes calldata cProof,
        externalEuint8 encCut, bytes calldata cutProof,
        externalEuint8 encColor, bytes calldata colProof,
        externalEuint8 encClarity, bytes calldata clProof,
        externalEuint64 encAppraisal, bytes calldata aProof
    ) external onlyGrader whenNotPaused returns (uint256 id) {
        require(certToId[certId] == 0, "Already registered");
        euint32 carat = FHE.fromExternal(encCarat, cProof);
        euint8 cut = FHE.fromExternal(encCut, cutProof);
        euint8 color = FHE.fromExternal(encColor, colProof);
        euint8 clarity = FHE.fromExternal(encClarity, clProof);
        euint64 appraisal = FHE.fromExternal(encAppraisal, aProof);
        id = diamondCount++;
        diamonds[id] = DiamondRecord({
            certificateId: certId, origin: origin,
            caratWeight: carat, cutGrade: cut, colorGrade: color, clarityGrade: clarity,
            appraisalValueUSD: appraisal, askingPriceUSD: FHE.asEuint64(0),
            currentOwner: initialOwner, status: TradingStatus.Graded,
            gradedAt: block.timestamp
        });
        certToId[certId] = id + 1;
        _totalMarketValueUSD = FHE.add(_totalMarketValueUSD, appraisal);
        FHE.allowThis(diamonds[id].caratWeight);
        FHE.allow(diamonds[id].caratWeight, initialOwner);
        FHE.allowThis(diamonds[id].cutGrade);
        FHE.allow(diamonds[id].cutGrade, initialOwner);
        FHE.allowThis(diamonds[id].colorGrade);
        FHE.allow(diamonds[id].colorGrade, initialOwner);
        FHE.allowThis(diamonds[id].clarityGrade);
        FHE.allow(diamonds[id].clarityGrade, initialOwner);
        FHE.allowThis(diamonds[id].appraisalValueUSD);
        FHE.allow(diamonds[id].appraisalValueUSD, initialOwner);
        FHE.allowThis(diamonds[id].askingPriceUSD);
        FHE.allowThis(_totalMarketValueUSD);
        emit DiamondRegistered(id, certId, origin);
    }

    function listDiamond(
        uint256 diamondId,
        externalEuint64 encAskingPrice, bytes calldata proof
    ) external {
        DiamondRecord storage d = diamonds[diamondId];
        require(d.currentOwner == msg.sender && d.status == TradingStatus.Graded, "Not owner or wrong status");
        euint64 price = FHE.fromExternal(encAskingPrice, proof);
        d.askingPriceUSD = price;
        d.status = TradingStatus.Listed;
        FHE.allowThis(d.askingPriceUSD);
        emit DiamondListed(diamondId);
    }

    function transferDiamond(
        uint256 diamondId,
        address to,
        externalEuint64 encPrice, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        require(isRegisteredDealer[msg.sender] || msg.sender == diamonds[diamondId].currentOwner, "Unauthorized");
        DiamondRecord storage d = diamonds[diamondId];
        require(d.status == TradingStatus.Listed || d.status == TradingStatus.Graded, "Not transferable");
        euint64 price = FHE.fromExternal(encPrice, proof);
        TransferRecord memory rec = TransferRecord({
            diamondId: diamondId, from: d.currentOwner, to: to,
            transactionPriceUSD: price, timestamp: block.timestamp
        });
        transferHistory[diamondId].push(rec);
        FHE.allowThis(price);
        FHE.allow(price, d.currentOwner);
        FHE.allow(price, to);
        _totalVolumeUSD = FHE.add(_totalVolumeUSD, price);
        FHE.allowThis(_totalVolumeUSD);
        d.currentOwner = to;
        d.status = TradingStatus.Sold;
        emit DiamondTransferred(diamondId, rec.from, to);
    }

    function allowDiamondDetails(uint256 diamondId, address viewer) external {
        DiamondRecord storage d = diamonds[diamondId];
        require(msg.sender == d.currentOwner || isGrader[msg.sender], "Unauthorized");
        FHE.allow(d.caratWeight, viewer);
        FHE.allow(d.cutGrade, viewer);
        FHE.allow(d.colorGrade, viewer);
        FHE.allow(d.clarityGrade, viewer);
        FHE.allow(d.appraisalValueUSD, viewer);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalMarketValueUSD, viewer);
        FHE.allow(_totalVolumeUSD, viewer);
    }
}
