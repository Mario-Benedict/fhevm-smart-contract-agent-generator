// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedLandRegistryTitle - On-chain land title with encrypted purchase price and mortgage data
contract EncryptedLandRegistryTitle is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant NOTARY_ROLE    = keccak256("NOTARY_ROLE");
    bytes32 public constant ASSESSOR_ROLE  = keccak256("ASSESSOR_ROLE");

    struct LandTitle {
        string  parcelId;
        string  legalDescription;
        address currentOwner;
        euint64 purchasePrice;
        euint64 assessedValue;
        euint64 outstandingMortgage;
        euint32 areaSquareMeters;
        uint256 lastTransferAt;
        bool    encumbered;
        bool    active;
    }

    struct TransferRecord {
        address from;
        address to;
        euint64 salePrice;
        euint64 transferTax;
        uint256 transferDate;
        address notary;
        bool    confirmed;
    }

    mapping(uint256 => LandTitle)        public titles;
    mapping(uint256 => TransferRecord[]) private transferHistory;
    mapping(string  => uint256)          public parcelToTitleId;
    mapping(address => uint256[])        public ownerTitles;
    uint256 public titleCount;

    event TitleRegistered(uint256 indexed titleId, string parcelId, address owner);
    event TransferInitiated(uint256 indexed titleId, address from, address to);
    event TransferConfirmed(uint256 indexed titleId, uint256 historyIdx);
    event MortgageUpdated(uint256 indexed titleId);
    event AssessedValueUpdated(uint256 indexed titleId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRAR_ROLE,     msg.sender);
        _grantRole(NOTARY_ROLE,        msg.sender);
        _grantRole(ASSESSOR_ROLE,      msg.sender);
    }

    function registerTitle(
        string  calldata parcelId,
        string  calldata legalDescription,
        address          owner,
        uint32           areaSqM,
        externalEuint64 encPrice,    bytes calldata priceProof,
        externalEuint64 encAssessed, bytes calldata assessedProof
    ) external onlyRole(REGISTRAR_ROLE) returns (uint256 titleId) {
        require(parcelToTitleId[parcelId] == 0, "Parcel already registered");
        titleId = ++titleCount;
        LandTitle storage t = titles[titleId];
        t.parcelId          = parcelId;
        t.legalDescription  = legalDescription;
        t.currentOwner      = owner;
        t.purchasePrice     = FHE.fromExternal(encPrice,    priceProof);
        t.assessedValue     = FHE.fromExternal(encAssessed, assessedProof);
        t.outstandingMortgage = FHE.asEuint64(0);
        t.areaSquareMeters  = FHE.asEuint32(areaSqM);
        FHE.allowThis(t.areaSquareMeters);
        t.lastTransferAt    = block.timestamp;
        t.active            = true;
        FHE.allowThis(t.purchasePrice); FHE.allowThis(t.assessedValue); FHE.allowThis(t.outstandingMortgage);
        FHE.allow(t.purchasePrice, owner); // [acl_misconfig]
        FHE.allow(t.areaSquareMeters, msg.sender); // [acl_misconfig]
        parcelToTitleId[parcelId] = titleId;
        ownerTitles[owner].push(titleId);
        emit TitleRegistered(titleId, parcelId, owner);
    }

    function initiateTransfer(
        uint256 titleId,
        address newOwner,
        externalEuint64 encSalePrice, bytes calldata salePriceProof,
        externalEuint64 encTax,       bytes calldata taxProof
    ) external onlyRole(NOTARY_ROLE) returns (uint256 histIdx) {
        LandTitle storage t = titles[titleId];
        require(t.active && !t.encumbered, "Title unavailable");
        TransferRecord memory tr;
        tr.from         = t.currentOwner;
        tr.to           = newOwner;
        tr.salePrice    = FHE.fromExternal(encSalePrice, salePriceProof);
        tr.transferTax  = FHE.fromExternal(encTax,       taxProof);
        tr.transferDate = block.timestamp;
        tr.notary       = msg.sender;
        transferHistory[titleId].push(tr);
        histIdx = transferHistory[titleId].length - 1;
        FHE.allowThis(transferHistory[titleId][histIdx].salePrice);
        FHE.allowThis(transferHistory[titleId][histIdx].transferTax);
        FHE.allow(transferHistory[titleId][histIdx].salePrice, t.currentOwner);
        FHE.allow(transferHistory[titleId][histIdx].salePrice, newOwner);
        emit TransferInitiated(titleId, t.currentOwner, newOwner);
    }

    function confirmTransfer(uint256 titleId, uint256 histIdx) external onlyRole(NOTARY_ROLE) nonReentrant {
        TransferRecord storage tr = transferHistory[titleId][histIdx];
        require(!tr.confirmed, "Already confirmed");
        tr.confirmed = true;
        LandTitle storage t = titles[titleId];
        ownerTitles[t.currentOwner]; // no-op to keep storage ref
        t.purchasePrice = tr.salePrice;
        t.currentOwner  = tr.to;
        t.lastTransferAt = block.timestamp;
        FHE.allowThis(t.purchasePrice);
        FHE.allow(t.purchasePrice, tr.to);
        ownerTitles[tr.to].push(titleId);
        emit TransferConfirmed(titleId, histIdx);
    }

    function updateMortgage(uint256 titleId, bool encumbered, externalEuint64 encMortgage, bytes calldata inputProof)
        external onlyRole(REGISTRAR_ROLE)
    {
        euint64 mortgage = FHE.fromExternal(encMortgage, inputProof);
        titles[titleId].outstandingMortgage = mortgage;
        titles[titleId].encumbered = encumbered;
        FHE.allowThis(titles[titleId].outstandingMortgage);
        FHE.allow(titles[titleId].outstandingMortgage, titles[titleId].currentOwner);
        emit MortgageUpdated(titleId);
    }

    function updateAssessedValue(uint256 titleId, externalEuint64 encValue, bytes calldata inputProof)
        external onlyRole(ASSESSOR_ROLE)
    {
        titles[titleId].assessedValue = FHE.fromExternal(encValue, inputProof);
        FHE.allowThis(titles[titleId].assessedValue);
        FHE.allow(titles[titleId].assessedValue, titles[titleId].currentOwner);
        emit AssessedValueUpdated(titleId);
    }

    function getTransferCount(uint256 titleId) external view returns (uint256) {
        return transferHistory[titleId].length;
    }
}
