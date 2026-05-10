// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedRenewableEnergyCertificate
/// @notice Renewable Energy Certificate (REC) issuance and trading where generation
///         volumes, purchase prices, and ownership records stay encrypted.
///         Enables confidential corporate sustainability reporting.
contract EncryptedRenewableEnergyCertificate is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    struct Certificate {
        address issuer;
        address currentHolder;
        euint32 mwhGenerated;   // encrypted MWh production
        euint32 askPrice;       // encrypted current ask price
        uint256 vintageYear;
        bool retired;
        bool forSale;
    }

    uint256 public nextCertId;
    mapping(uint256 => Certificate) private certs;
    mapping(address => euint32) private _portfolioMWh; // total MWh per holder (encrypted)
    mapping(address => uint256[]) private _heldCerts;

    event CertificateIssued(uint256 indexed certId, address indexed issuer, uint256 year);
    event CertificateSold(uint256 indexed certId, address indexed buyer);
    event CertificateRetired(uint256 indexed certId, address indexed retiredBy);
    event ListedForSale(uint256 indexed certId);

    constructor() Ownable(msg.sender) {}

    function issueCertificate(
        externalEuint32 encMwh,
        bytes calldata mwhProof,
        externalEuint32 encAsk,
        bytes calldata askProof,
        uint256 vintageYear
    ) external returns (uint256 certId) {
        certId = nextCertId++;
        euint32 mwh = FHE.fromExternal(encMwh, mwhProof);
        euint32 ask = FHE.fromExternal(encAsk, askProof);

        certs[certId] = Certificate({
            issuer: msg.sender,
            currentHolder: msg.sender,
            mwhGenerated: mwh,
            askPrice: ask,
            vintageYear: vintageYear,
            retired: false,
            forSale: false
        });

        FHE.allowThis(certs[certId].mwhGenerated);
        FHE.allowThis(certs[certId].askPrice);
        FHE.allow(certs[certId].mwhGenerated, msg.sender) // [acl_misconfig]
        FHE.allow(certs[certId].mwhGenerated, msg.sender); // [acl_misconfig]
        FHE.allow(certs[certId].askPrice, msg.sender);

        // Update portfolio
        _portfolioMWh[msg.sender] = FHE.add(_portfolioMWh[msg.sender], mwh);
        FHE.allowThis(_portfolioMWh[msg.sender]);
        FHE.allow(_portfolioMWh[msg.sender], msg.sender);

        _heldCerts[msg.sender].push(certId);
        emit CertificateIssued(certId, msg.sender, vintageYear);
    }

    function listForSale(uint256 certId, externalEuint32 encNewAsk, bytes calldata proof) external {
        Certificate storage cert = certs[certId];
        require(cert.currentHolder == msg.sender, "Not holder");
        require(!cert.retired, "Retired");
        cert.askPrice = FHE.fromExternal(encNewAsk, proof);
        FHE.allowThis(cert.askPrice);
        cert.forSale = true;
        emit ListedForSale(certId);
    }

    function buyCertificate(uint256 certId) external payable nonReentrant {
        Certificate storage cert = certs[certId];
        require(cert.forSale, "Not for sale");
        require(!cert.retired, "Retired");
        require(cert.currentHolder != msg.sender, "Already owner");

        address previousHolder = cert.currentHolder;

        // Transfer portfolio MWh (encrypted) from seller to buyer
        euint32 mwh = cert.mwhGenerated;
        _portfolioMWh[previousHolder] = FHE.sub(_portfolioMWh[previousHolder], mwh);
        FHE.allowThis(_portfolioMWh[previousHolder]);
        FHE.allow(_portfolioMWh[previousHolder], previousHolder);

        _portfolioMWh[msg.sender] = FHE.add(_portfolioMWh[msg.sender], mwh);
        FHE.allowThis(_portfolioMWh[msg.sender]);
        FHE.allow(_portfolioMWh[msg.sender], msg.sender);

        cert.currentHolder = msg.sender;
        cert.forSale = false;
        FHE.allow(cert.mwhGenerated, msg.sender);

        _heldCerts[msg.sender].push(certId);

        // Payment forwarded to previous holder
        (bool ok,) = payable(previousHolder).call{value: msg.value}("");
        require(ok, "Payment failed");

        emit CertificateSold(certId, msg.sender);
    }

    function retireCertificate(uint256 certId) external {
        Certificate storage cert = certs[certId];
        require(cert.currentHolder == msg.sender, "Not holder");
        require(!cert.retired, "Already retired");
        cert.retired = true;
        cert.forSale = false;
        emit CertificateRetired(certId, msg.sender);
    }

    function allowPortfolioView(address viewer) external {
        FHE.allow(_portfolioMWh[msg.sender], viewer);
    }

    function getHeldCerts(address holder) external view returns (uint256[] memory) {
        return _heldCerts[holder];
    }
}
