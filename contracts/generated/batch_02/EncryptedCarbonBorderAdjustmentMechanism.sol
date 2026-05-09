// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCarbonBorderAdjustmentMechanism
/// @notice EU CBAM compliance: encrypted embedded carbon in imported goods,
///         encrypted CBAM certificate prices, and encrypted sectoral adjustments.
contract EncryptedCarbonBorderAdjustmentMechanism is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CBAMSector { Steel, Aluminum, Cement, Fertilizer, Electricity, Hydrogen }
    enum DeclarationStatus { Draft, Submitted, Verified, Accepted, Disputed }

    struct CBAMDeclaration {
        address importer;
        string originCountry;
        CBAMSector sector;
        string cnCode;                   // Combined Nomenclature code
        euint64 importQuantityTonnes;    // encrypted import volume
        euint64 embeddedCarbonTonnes;    // encrypted embedded CO2e
        euint64 carbonPricePaidUSD;      // encrypted carbon price paid in origin
        euint64 cbamObligationUSD;       // encrypted CBAM fee due
        euint64 certificatesRequired;    // encrypted CBAM certificates needed
        uint256 declarationPeriod;       // Unix timestamp for quarter
        DeclarationStatus status;
    }

    struct CBAMCertificate {
        address holder;
        euint64 carbonTonnesCovered;     // encrypted tonnes covered
        euint64 purchasePriceUSD;        // encrypted purchase price
        bool surrendered;
        uint256 issuedAt;
    }

    mapping(uint256 => CBAMDeclaration) private declarations;
    mapping(uint256 => CBAMCertificate) private certificates;
    mapping(address => bool) public isDeclarantAgent;
    mapping(address => bool) public isCBAMAuthority;

    uint256 public declarationCount;
    uint256 public certificateCount;
    euint64 private _totalEmbeddedCarbon;
    euint64 private _totalCBAMObligations;
    euint64 private _totalCertificateRevenue;

    event DeclarationFiled(uint256 indexed id, CBAMSector sector, string originCountry);
    event DeclarationVerified(uint256 indexed id);
    event CertificateIssued(uint256 indexed id, address holder);
    event CertificateSurrendered(uint256 indexed certId, uint256 declarationId);

    modifier onlyAuthority() {
        require(isCBAMAuthority[msg.sender] || msg.sender == owner(), "Not CBAM authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEmbeddedCarbon = FHE.asEuint64(0);
        _totalCBAMObligations = FHE.asEuint64(0);
        _totalCertificateRevenue = FHE.asEuint64(0);
        FHE.allowThis(_totalEmbeddedCarbon);
        FHE.allowThis(_totalCBAMObligations);
        FHE.allowThis(_totalCertificateRevenue);
        isCBAMAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isCBAMAuthority[a] = true; }
    function addAgent(address a) external onlyOwner { isDeclarantAgent[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function fileDeclaration(
        string calldata originCountry, CBAMSector sector, string calldata cnCode,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint64 encEmbedded, bytes calldata eProof,
        externalEuint64 encPricePaid, bytes calldata ppProof,
        externalEuint64 encObligation, bytes calldata oProof,
        uint256 period
    ) external whenNotPaused returns (uint256 id) {
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint64 embedded = FHE.fromExternal(encEmbedded, eProof);
        euint64 pricePaid = FHE.fromExternal(encPricePaid, ppProof);
        euint64 obligation = FHE.fromExternal(encObligation, oProof);
        id = declarationCount++;
        declarations[id].importer = msg.sender;
        declarations[id].originCountry = originCountry;
        declarations[id].sector = sector;
        declarations[id].cnCode = cnCode;
        declarations[id].importQuantityTonnes = qty;
        declarations[id].embeddedCarbonTonnes = embedded;
        declarations[id].carbonPricePaidUSD = pricePaid;
        declarations[id].cbamObligationUSD = obligation;
        declarations[id].certificatesRequired = embedded;
        declarations[id].declarationPeriod = period;
        declarations[id].status = DeclarationStatus.Submitted;
        _totalEmbeddedCarbon = FHE.add(_totalEmbeddedCarbon, embedded);
        _totalCBAMObligations = FHE.add(_totalCBAMObligations, obligation);
        FHE.allowThis(declarations[id].importQuantityTonnes); FHE.allow(declarations[id].importQuantityTonnes, msg.sender);
        FHE.allowThis(declarations[id].embeddedCarbonTonnes); FHE.allow(declarations[id].embeddedCarbonTonnes, msg.sender);
        FHE.allowThis(declarations[id].carbonPricePaidUSD); FHE.allow(declarations[id].carbonPricePaidUSD, msg.sender);
        FHE.allowThis(declarations[id].cbamObligationUSD); FHE.allow(declarations[id].cbamObligationUSD, msg.sender);
        FHE.allowThis(declarations[id].certificatesRequired); FHE.allow(declarations[id].certificatesRequired, msg.sender);
        FHE.allowThis(_totalEmbeddedCarbon);
        FHE.allowThis(_totalCBAMObligations);
        emit DeclarationFiled(id, sector, originCountry);
    }

    function verifyDeclaration(uint256 declarationId) external onlyAuthority {
        declarations[declarationId].status = DeclarationStatus.Verified;
        emit DeclarationVerified(declarationId);
    }

    function issueCertificate(
        address holder,
        externalEuint64 encTonnes, bytes calldata tProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        euint64 tonnes = FHE.fromExternal(encTonnes, tProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        id = certificateCount++;
        certificates[id] = CBAMCertificate({
            holder: holder, carbonTonnesCovered: tonnes, purchasePriceUSD: price,
            surrendered: false, issuedAt: block.timestamp
        });
        _totalCertificateRevenue = FHE.add(_totalCertificateRevenue, price);
        FHE.allowThis(certificates[id].carbonTonnesCovered); FHE.allow(certificates[id].carbonTonnesCovered, holder);
        FHE.allowThis(certificates[id].purchasePriceUSD); FHE.allow(certificates[id].purchasePriceUSD, holder);
        FHE.allowThis(_totalCertificateRevenue);
        emit CertificateIssued(id, holder);
    }

    function surrenderCertificate(uint256 certId, uint256 declarationId) external nonReentrant {
        CBAMCertificate storage c = certificates[certId];
        require(c.holder == msg.sender && !c.surrendered, "Not holder or already surrendered");
        CBAMDeclaration storage d = declarations[declarationId];
        require(d.importer == msg.sender && d.status == DeclarationStatus.Verified, "Not authorized");
        c.surrendered = true;
        d.status = DeclarationStatus.Accepted;
        FHE.allow(c.carbonTonnesCovered, owner());
        emit CertificateSurrendered(certId, declarationId);
    }

    function allowCBAMStats(address viewer) external onlyOwner {
        FHE.allow(_totalEmbeddedCarbon, viewer);
        FHE.allow(_totalCBAMObligations, viewer);
        FHE.allow(_totalCertificateRevenue, viewer);
    }
}
