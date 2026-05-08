// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedLuxuryWatchAuthentication
/// @notice Luxury watch provenance and authentication system. Encrypted serial numbers,
///         encrypted service history costs, and encrypted market valuations.
contract EncryptedLuxuryWatchAuthentication is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WatchBrand { Patek, Rolex, AP, Lange, Vacheron, IWC, Breguet, Jaeger }
    enum AuthStatus { Unverified, Authenticated, Suspect, Stolen }

    struct LuxuryWatch {
        address currentOwner;
        WatchBrand brand;
        string modelName;
        string referenceNumber;
        euint32 serialHash;             // encrypted serial number hash
        euint64 originalRetailUSD;      // encrypted original retail price
        euint64 currentInsuredValueUSD; // encrypted insured value
        euint64 lastServiceCostUSD;     // encrypted last service cost
        euint16 conditionScore;         // encrypted condition (0-100)
        uint256 manufactureYear;
        AuthStatus status;
    }

    struct ServiceRecord {
        uint256 watchId;
        address serviceCenter;
        string workPerformed;
        euint64 serviceFeePaid;         // encrypted service cost
        uint256 serviceDate;
        bool warrantyWork;
    }

    struct TransferLog {
        uint256 watchId;
        address from;
        address to;
        euint64 salePrice;              // encrypted transaction price
        uint256 transferDate;
    }

    mapping(uint256 => LuxuryWatch) private watches;
    mapping(uint256 => ServiceRecord[]) private serviceHistory;
    mapping(uint256 => TransferLog[]) private transferHistory;
    mapping(address => bool) public isAuthorizedDealer;
    mapping(address => bool) public isAuthenticator;

    uint256 public watchCount;
    euint64 private _totalRegisteredValue;
    euint64 private _totalSalesVolume;

    event WatchRegistered(uint256 indexed id, WatchBrand brand, string refNumber);
    event WatchAuthenticated(uint256 indexed id);
    event WatchTransferred(uint256 indexed id, address from, address to);
    event WatchFlaggedStolen(uint256 indexed id);

    modifier onlyAuthenticator() {
        require(isAuthenticator[msg.sender] || msg.sender == owner(), "Not authenticator");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRegisteredValue = FHE.asEuint64(0);
        _totalSalesVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalRegisteredValue);
        FHE.allowThis(_totalSalesVolume);
        isAuthenticator[msg.sender] = true;
    }

    function addDealer(address d) external onlyOwner { isAuthorizedDealer[d] = true; }
    function addAuthenticator(address a) external onlyOwner { isAuthenticator[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerWatch(
        WatchBrand brand,
        string calldata modelName,
        string calldata refNumber,
        uint256 manufactureYear,
        externalEuint32 encSerial, bytes calldata sProof,
        externalEuint64 encRetail, bytes calldata rProof,
        externalEuint64 encInsured, bytes calldata iProof,
        externalEuint16 encCondition, bytes calldata cProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 serial = FHE.fromExternal(encSerial, sProof);
        euint64 retail = FHE.fromExternal(encRetail, rProof);
        euint64 insured = FHE.fromExternal(encInsured, iProof);
        euint16 condition = FHE.fromExternal(encCondition, cProof);
        id = watchCount++;
        watches[id] = LuxuryWatch({
            currentOwner: msg.sender, brand: brand, modelName: modelName,
            referenceNumber: refNumber, serialHash: serial,
            originalRetailUSD: retail, currentInsuredValueUSD: insured,
            lastServiceCostUSD: FHE.asEuint64(0), conditionScore: condition,
            manufactureYear: manufactureYear, status: AuthStatus.Unverified
        });
        _totalRegisteredValue = FHE.add(_totalRegisteredValue, retail);
        FHE.allowThis(watches[id].serialHash);
        FHE.allow(watches[id].serialHash, msg.sender);
        FHE.allowThis(watches[id].originalRetailUSD);
        FHE.allow(watches[id].originalRetailUSD, msg.sender);
        FHE.allowThis(watches[id].currentInsuredValueUSD);
        FHE.allow(watches[id].currentInsuredValueUSD, msg.sender);
        FHE.allowThis(watches[id].lastServiceCostUSD);
        FHE.allowThis(watches[id].conditionScore);
        FHE.allow(watches[id].conditionScore, msg.sender);
        FHE.allowThis(_totalRegisteredValue);
        emit WatchRegistered(id, brand, refNumber);
    }

    function authenticateWatch(uint256 watchId) external onlyAuthenticator {
        watches[watchId].status = AuthStatus.Authenticated;
        emit WatchAuthenticated(watchId);
    }

    function recordService(
        uint256 watchId,
        string calldata workDone,
        externalEuint64 encFee, bytes calldata fProof,
        bool warranty
    ) external {
        require(isAuthorizedDealer[msg.sender], "Not authorized dealer");
        LuxuryWatch storage w = watches[watchId];
        euint64 fee = FHE.fromExternal(encFee, fProof);
        w.lastServiceCostUSD = fee;
        ServiceRecord memory rec = ServiceRecord({
            watchId: watchId, serviceCenter: msg.sender, workPerformed: workDone,
            serviceFeePaid: fee, serviceDate: block.timestamp, warrantyWork: warranty
        });
        serviceHistory[watchId].push(rec);
        FHE.allowThis(fee);
        FHE.allow(fee, w.currentOwner);
        FHE.allowThis(w.lastServiceCostUSD);
        FHE.allow(w.lastServiceCostUSD, w.currentOwner);
    }

    function transferWatch(
        uint256 watchId,
        address to,
        externalEuint64 encSalePrice, bytes calldata proof
    ) external nonReentrant whenNotPaused {
        LuxuryWatch storage w = watches[watchId];
        require(w.currentOwner == msg.sender && w.status == AuthStatus.Authenticated, "Cannot transfer");
        euint64 price = FHE.fromExternal(encSalePrice, proof);
        TransferLog memory log = TransferLog({
            watchId: watchId, from: msg.sender, to: to,
            salePrice: price, transferDate: block.timestamp
        });
        transferHistory[watchId].push(log);
        _totalSalesVolume = FHE.add(_totalSalesVolume, price);
        FHE.allowThis(price);
        FHE.allow(price, msg.sender);
        FHE.allow(price, to);
        FHE.allowThis(_totalSalesVolume);
        w.currentOwner = to;
        emit WatchTransferred(watchId, msg.sender, to);
    }

    function flagStolen(uint256 watchId) external onlyAuthenticator {
        watches[watchId].status = AuthStatus.Stolen;
        emit WatchFlaggedStolen(watchId);
    }

    function updateInsuredValue(uint256 watchId, externalEuint64 encValue, bytes calldata proof) external {
        require(watches[watchId].currentOwner == msg.sender, "Not owner");
        watches[watchId].currentInsuredValueUSD = FHE.fromExternal(encValue, proof);
        FHE.allowThis(watches[watchId].currentInsuredValueUSD);
        FHE.allow(watches[watchId].currentInsuredValueUSD, msg.sender);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalRegisteredValue, viewer);
        FHE.allow(_totalSalesVolume, viewer);
    }
}
