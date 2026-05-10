// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateForestCarbonSequestration
/// @notice Forest owners register encrypted sequestration volumes verified by satellite.
///         Encrypted carbon credits issued proportional to biomass growth rate.
contract PrivateForestCarbonSequestration is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum ForestType { Temperate, Tropical, Boreal, Mangrove, Savanna }
    enum VerificationStatus { Pending, Verified, Disputed, Revoked }

    struct ForestPlot {
        address landowner;
        ForestType forestType;
        string country;
        string plotId;
        euint32 areaHectares;              // encrypted plot area
        euint32 treeDensityPerHa;          // encrypted tree density
        euint64 baselineCarbonTonnes;      // encrypted baseline carbon stock
        euint64 currentCarbonTonnes;       // encrypted current carbon stock
        euint64 additionalityTonnes;       // encrypted additional sequestration
        euint32 leakageRiskBps;            // encrypted leakage risk score
        uint256 registrationDate;
        VerificationStatus status;
    }

    struct CarbonCredit {
        uint256 plotId;
        euint64 quantityTonnes;            // encrypted credit volume
        euint32 permanenceScore;           // encrypted permanence rating
        euint64 priceUSD;                  // encrypted price if listed
        bool listed;
        bool retired;
        address holder;
    }

    mapping(uint256 => ForestPlot) private plots;
    mapping(uint256 => CarbonCredit[]) private credits;
    mapping(address => bool) public isForestVerifier;
    mapping(address => bool) public isBuyer;

    uint256 public plotCount;
    euint64 private _totalSequesteredTonnes;
    euint64 private _totalRetiredTonnes;

    event PlotRegistered(uint256 indexed id, ForestType fType, string country);
    event PlotVerified(uint256 indexed id);
    event CreditsIssued(uint256 indexed plotId, uint256 creditIndex);
    event CreditRetired(uint256 indexed plotId, uint256 creditIndex, address retiree);

    modifier onlyVerifier() {
        require(isForestVerifier[msg.sender] || msg.sender == owner(), "Not verifier");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSequesteredTonnes = FHE.asEuint64(0);
        _totalRetiredTonnes = FHE.asEuint64(0);
        FHE.allowThis(_totalSequesteredTonnes);
        FHE.allowThis(_totalRetiredTonnes);
        isForestVerifier[msg.sender] = true;
    }

    function addVerifier(address v) external onlyOwner { isForestVerifier[v] = true; }
    function addBuyer(address b) external onlyOwner { isBuyer[b] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerPlot(
        ForestType fType, string calldata country, string calldata plotId,
        externalEuint32 encArea, bytes calldata aProof,
        externalEuint32 encDensity, bytes calldata dProof,
        externalEuint64 encBaseline, bytes calldata bProof,
        externalEuint32 encLeakage, bytes calldata lProof
    ) external whenNotPaused returns (uint256 id) {
        euint32 area = FHE.fromExternal(encArea, aProof);
        euint32 density = FHE.fromExternal(encDensity, dProof);
        euint64 baseline = FHE.fromExternal(encBaseline, bProof);
        euint32 leakage = FHE.fromExternal(encLeakage, lProof);
        id = plotCount++;
        ForestPlot storage _s0 = plots[id];
        _s0.landowner = msg.sender;
        _s0.forestType = fType;
        _s0.country = country;
        _s0.plotId = plotId;
        _s0.areaHectares = area;
        _s0.treeDensityPerHa = density;
        _s0.baselineCarbonTonnes = baseline;
        _s0.currentCarbonTonnes = baseline;
        _s0.additionalityTonnes = FHE.asEuint64(0);
        _s0.leakageRiskBps = leakage;
        _s0.registrationDate = block.timestamp;
        _s0.status = VerificationStatus.Pending;
        FHE.allowThis(plots[id].areaHectares); FHE.allow(plots[id].areaHectares, msg.sender);
        FHE.allowThis(plots[id].treeDensityPerHa);
        FHE.allowThis(plots[id].baselineCarbonTonnes); FHE.allow(plots[id].baselineCarbonTonnes, msg.sender);
        FHE.allowThis(plots[id].currentCarbonTonnes); FHE.allow(plots[id].currentCarbonTonnes, msg.sender);
        FHE.allowThis(plots[id].additionalityTonnes);
        FHE.allowThis(plots[id].leakageRiskBps);
        emit PlotRegistered(id, fType, country);
    }

    function verifyPlot(
        uint256 plotId,
        externalEuint64 encCurrent, bytes calldata cProof,
        externalEuint64 encAdditionality, bytes calldata addProof
    ) external onlyVerifier {
        ForestPlot storage p = plots[plotId];
        euint64 current = FHE.fromExternal(encCurrent, cProof);
        euint64 additionality = FHE.fromExternal(encAdditionality, addProof);
        p.currentCarbonTonnes = current;
        p.additionalityTonnes = additionality;
        p.status = VerificationStatus.Verified;
        _totalSequesteredTonnes = FHE.add(_totalSequesteredTonnes, additionality);
        FHE.allowThis(p.currentCarbonTonnes); FHE.allow(p.currentCarbonTonnes, p.landowner);
        FHE.allowThis(p.additionalityTonnes); FHE.allow(p.additionalityTonnes, p.landowner);
        FHE.allowThis(_totalSequesteredTonnes);
        emit PlotVerified(plotId);
    }

    function issueCredit(
        uint256 plotId,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint32 encPermanence, bytes calldata pProof,
        externalEuint64 encPrice, bytes calldata prProof
    ) external onlyVerifier returns (uint256 creditIndex) {
        require(plots[plotId].status == VerificationStatus.Verified, "Not verified");
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint32 permanence = FHE.fromExternal(encPermanence, pProof);
        euint64 price = FHE.fromExternal(encPrice, prProof);
        credits[plotId].push(CarbonCredit({
            plotId: plotId, quantityTonnes: qty, permanenceScore: permanence,
            priceUSD: price, listed: true, retired: false, holder: plots[plotId].landowner
        }));
        creditIndex = credits[plotId].length - 1;
        FHE.allowThis(qty); FHE.allow(qty, plots[plotId].landowner);
        FHE.allowThis(permanence); FHE.allow(permanence, plots[plotId].landowner);
        FHE.allowThis(price);
        emit CreditsIssued(plotId, creditIndex);
    }

    function purchaseCredit(uint256 plotId, uint256 creditIndex) external whenNotPaused nonReentrant {
        require(isBuyer[msg.sender], "Not buyer");
        CarbonCredit storage c = credits[plotId][creditIndex];
        require(c.listed && !c.retired, "Not available");
        address prev = c.holder;
        c.holder = msg.sender;
        c.listed = false;
        FHE.allow(c.quantityTonnes, msg.sender);
        FHE.allow(c.priceUSD, prev);
    }

    function retireCredit(uint256 plotId, uint256 creditIndex) external {
        CarbonCredit storage c = credits[plotId][creditIndex];
        require(c.holder == msg.sender && !c.retired, "Cannot retire");
        c.retired = true;
        _totalRetiredTonnes = FHE.add(_totalRetiredTonnes, c.quantityTonnes);
        FHE.allowThis(_totalRetiredTonnes);
        emit CreditRetired(plotId, creditIndex, msg.sender);
    }

    function allowRegistryStats(address viewer) external onlyOwner {
        FHE.allow(_totalSequesteredTonnes, viewer);
        FHE.allow(_totalRetiredTonnes, viewer);
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