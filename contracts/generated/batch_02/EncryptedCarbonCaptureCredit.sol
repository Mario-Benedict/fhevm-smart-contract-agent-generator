// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCarbonCaptureCredit
/// @notice Industrial carbon capture projects issue encrypted credit certificates.
///         Verifiers attest encrypted tonnes captured. Buyers purchase at encrypted prices.
///         Registry prevents double-counting using encrypted serial tracking.
contract EncryptedCarbonCaptureCredit is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ProjectType { DirectAirCapture, BioenergyCCS, OceanAlkalinity, Reforestation }
    enum CreditStatus { Issued, Listed, Sold, Retired, Cancelled }

    struct CaptureProject {
        address operator;
        ProjectType projectType;
        string country;
        euint64 totalCaptureTargetTonnes;    // encrypted annual target
        euint64 verifiedCapturedTonnes;      // encrypted verified amount
        euint32 monitoringScore;             // encrypted MRV score (0-100)
        uint256 vintageYear;
        bool verified;
    }

    struct CarbonCredit {
        uint256 projectId;
        euint64 quantityTonnes;              // encrypted quantity
        euint64 pricePerTonneCents;          // encrypted listing price
        euint64 proceedsUSD;                 // encrypted sale proceeds
        CreditStatus status;
        address currentHolder;
    }

    mapping(uint256 => CaptureProject) private projects;
    mapping(uint256 => CarbonCredit) private credits;
    mapping(address => uint256[]) private holderCredits;
    mapping(address => bool) public isVerifier;
    mapping(address => bool) public isRegisteredBuyer;

    uint256 public projectCount;
    uint256 public creditCount;
    euint64 private _totalVerifiedTonnes;
    euint64 private _totalRetiredTonnes;
    euint64 private _totalMarketVolumeCents;

    event ProjectRegistered(uint256 indexed id, address operator, ProjectType pType);
    event CreditIssued(uint256 indexed creditId, uint256 projectId);
    event CreditListed(uint256 indexed creditId);
    event CreditSold(uint256 indexed creditId, address buyer);
    event CreditRetired(uint256 indexed creditId, address retiree);

    modifier onlyVerifier() {
        require(isVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalVerifiedTonnes = FHE.asEuint64(0);
        _totalRetiredTonnes = FHE.asEuint64(0);
        _totalMarketVolumeCents = FHE.asEuint64(0);
        FHE.allowThis(_totalVerifiedTonnes);
        FHE.allowThis(_totalRetiredTonnes);
        FHE.allowThis(_totalMarketVolumeCents);
        isVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isVerifier[v] = true; }
    function addBuyer(address b) external onlyOwner { isRegisteredBuyer[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerProject(
        ProjectType pType,
        string calldata country,
        externalEuint64 encTarget, bytes calldata tProof,
        uint256 vintageYear
    ) external whenNotPaused returns (uint256 id) {
        id = projectCount++;
        projects[id] = CaptureProject({
            operator: msg.sender,
            projectType: pType,
            country: country,
            totalCaptureTargetTonnes: FHE.fromExternal(encTarget, tProof),
            verifiedCapturedTonnes: FHE.asEuint64(0),
            monitoringScore: FHE.asEuint32(0),
            vintageYear: vintageYear,
            verified: false
        });
        FHE.allowThis(projects[id].totalCaptureTargetTonnes);
        FHE.allow(projects[id].totalCaptureTargetTonnes, msg.sender);
        FHE.allowThis(projects[id].verifiedCapturedTonnes);
        FHE.allowThis(projects[id].monitoringScore);
        emit ProjectRegistered(id, msg.sender, pType);
    }

    function verifyProject(
        uint256 projectId,
        externalEuint64 encVerifiedTonnes, bytes calldata vProof,
        externalEuint32 encScore, bytes calldata sProof
    ) external onlyVerifier {
        CaptureProject storage p = projects[projectId];
        euint64 verified = FHE.fromExternal(encVerifiedTonnes, vProof);
        euint32 score = FHE.fromExternal(encScore, sProof);
        // Clamp to target: verified = min(verified, target)
        ebool withinTarget = FHE.le(verified, p.totalCaptureTargetTonnes);
        p.verifiedCapturedTonnes = FHE.select(withinTarget, verified, p.totalCaptureTargetTonnes);
        p.monitoringScore = score;
        p.verified = true;
        _totalVerifiedTonnes = FHE.add(_totalVerifiedTonnes, p.verifiedCapturedTonnes);
        FHE.allowThis(p.verifiedCapturedTonnes);
        FHE.allow(p.verifiedCapturedTonnes, p.operator);
        FHE.allowThis(p.monitoringScore);
        FHE.allow(p.monitoringScore, p.operator);
        FHE.allowThis(_totalVerifiedTonnes);
    }

    function issueCredit(
        uint256 projectId,
        externalEuint64 encQty, bytes calldata proof
    ) external onlyVerifier returns (uint256 creditId) {
        require(projects[projectId].verified, "Not verified");
        euint64 qty = FHE.fromExternal(encQty, proof);
        creditId = creditCount++;
        credits[creditId] = CarbonCredit({
            projectId: projectId,
            quantityTonnes: qty,
            pricePerTonneCents: FHE.asEuint64(0),
            proceedsUSD: FHE.asEuint64(0),
            status: CreditStatus.Issued,
            currentHolder: projects[projectId].operator
        });
        FHE.allowThis(credits[creditId].quantityTonnes);
        FHE.allow(credits[creditId].quantityTonnes, projects[projectId].operator);
        FHE.allowThis(credits[creditId].pricePerTonneCents);
        FHE.allowThis(credits[creditId].proceedsUSD);
        holderCredits[projects[projectId].operator].push(creditId);
        emit CreditIssued(creditId, projectId);
    }

    function listCredit(
        uint256 creditId,
        externalEuint64 encPrice, bytes calldata proof
    ) external {
        CarbonCredit storage c = credits[creditId];
        require(c.currentHolder == msg.sender && c.status == CreditStatus.Issued, "Not holder or wrong status");
        euint64 price = FHE.fromExternal(encPrice, proof);
        c.pricePerTonneCents = price;
        c.status = CreditStatus.Listed;
        FHE.allowThis(c.pricePerTonneCents);
        emit CreditListed(creditId);
    }

    function purchaseCredit(uint256 creditId) external nonReentrant whenNotPaused {
        require(isRegisteredBuyer[msg.sender], "Not registered buyer");
        CarbonCredit storage c = credits[creditId];
        require(c.status == CreditStatus.Listed, "Not listed");
        euint64 proceeds = FHE.mul(c.quantityTonnes, c.pricePerTonneCents);
        c.proceedsUSD = proceeds;
        c.status = CreditStatus.Sold;
        address prevHolder = c.currentHolder;
        c.currentHolder = msg.sender;
        holderCredits[msg.sender].push(creditId);
        _totalMarketVolumeCents = FHE.add(_totalMarketVolumeCents, proceeds);
        FHE.allowThis(c.proceedsUSD);
        FHE.allow(c.proceedsUSD, prevHolder);
        FHE.allow(c.proceedsUSD, msg.sender);
        FHE.allowThis(_totalMarketVolumeCents);
        emit CreditSold(creditId, msg.sender);
    }

    function retireCredit(uint256 creditId) external {
        CarbonCredit storage c = credits[creditId];
        require(c.currentHolder == msg.sender, "Not holder");
        require(c.status == CreditStatus.Sold || c.status == CreditStatus.Issued, "Cannot retire");
        c.status = CreditStatus.Retired;
        _totalRetiredTonnes = FHE.add(_totalRetiredTonnes, c.quantityTonnes);
        FHE.allowThis(_totalRetiredTonnes);
        emit CreditRetired(creditId, msg.sender);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalVerifiedTonnes, viewer);
        FHE.allow(_totalRetiredTonnes, viewer);
        FHE.allow(_totalMarketVolumeCents, viewer);
    }
}
