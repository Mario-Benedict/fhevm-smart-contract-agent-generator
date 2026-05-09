// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateForestCarbonSequestrationVault
/// @notice Forestry carbon credit vault with encrypted biomass measurements,
///         growth rates, and landowner payment schedules.
contract PrivateForestCarbonSequestrationVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ForestPlot {
        string plotId;
        address landowner;
        euint64 areaCubicMeters;       // encrypted volume
        euint64 carbonTonnesAnnual;    // encrypted annual sequestration
        euint64 creditPriceUSD;        // encrypted price per tonne
        euint64 annualPaymentUSD;      // encrypted payment to landowner
        euint64 totalPaymentsUSD;      // encrypted cumulative paid
        euint8  forestHealthScore;     // encrypted health rating 0-100
        euint8  deforestationRiskScore;// encrypted risk 0-100
        uint256 verificationDate;
        bool verified;
    }

    mapping(uint256 => ForestPlot) private plots;
    mapping(address => bool) public isForestryAuditor;
    uint256 public plotCount;
    euint64 private _totalForestCarbon;
    euint64 private _totalForestPayments;

    event PlotRegistered(uint256 indexed plotId);
    event CarbonVerified(uint256 indexed plotId);
    event PaymentMade(uint256 indexed plotId);

    constructor() Ownable(msg.sender) {
        _totalForestCarbon = FHE.asEuint64(0);
        _totalForestPayments = FHE.asEuint64(0);
        FHE.allowThis(_totalForestCarbon);
        FHE.allowThis(_totalForestPayments);
        isForestryAuditor[msg.sender] = true;
    }

    function addAuditor(address a) external onlyOwner { isForestryAuditor[a] = true; }

    function registerPlot(
        string calldata plotId, address landowner,
        externalEuint64 encArea,    bytes calldata aProof,
        externalEuint64 encCarbon,  bytes calldata cProof,
        externalEuint64 encPrice,   bytes calldata pProof,
        externalEuint8  encHealth,  bytes calldata hProof,
        externalEuint8  encRisk,    bytes calldata rProof
    ) external returns (uint256 pid) {
        require(isForestryAuditor[msg.sender], "Not auditor");
        euint64 area    = FHE.fromExternal(encArea, aProof);
        euint64 carbon  = FHE.fromExternal(encCarbon, cProof);
        euint64 price   = FHE.fromExternal(encPrice, pProof);
        euint8  health  = FHE.fromExternal(encHealth, hProof);
        euint8  risk    = FHE.fromExternal(encRisk, rProof);
        euint64 payment = FHE.mul(carbon, price);
        pid = plotCount++;
        plots[pid].plotId = plotId;
        plots[pid].landowner = landowner;
        plots[pid].areaCubicMeters = area;
        plots[pid].carbonTonnesAnnual = carbon;
        plots[pid].creditPriceUSD = price;
        plots[pid].annualPaymentUSD = payment;
        plots[pid].totalPaymentsUSD = FHE.asEuint64(0);
        plots[pid].forestHealthScore = health;
        plots[pid].deforestationRiskScore = risk;
        plots[pid].verificationDate = block.timestamp;
        plots[pid].verified = false;
        _totalForestCarbon = FHE.add(_totalForestCarbon, carbon);
        FHE.allowThis(plots[pid].areaCubicMeters);
        FHE.allowThis(plots[pid].carbonTonnesAnnual);
        FHE.allowThis(plots[pid].creditPriceUSD);
        FHE.allowThis(plots[pid].annualPaymentUSD);
        FHE.allow(plots[pid].annualPaymentUSD, landowner);
        FHE.allowThis(plots[pid].totalPaymentsUSD);
        FHE.allow(plots[pid].totalPaymentsUSD, landowner);
        FHE.allowThis(plots[pid].forestHealthScore);
        FHE.allowThis(plots[pid].deforestationRiskScore);
        FHE.allowThis(_totalForestCarbon);
        emit PlotRegistered(pid);
    }

    function verifyCarbon(uint256 pid) external {
        require(isForestryAuditor[msg.sender], "Not auditor");
        plots[pid].verified = true;
        emit CarbonVerified(pid);
    }

    function makeAnnualPayment(uint256 pid) external {
        require(isForestryAuditor[msg.sender] || msg.sender == owner(), "Unauthorized");
        require(plots[pid].verified, "Not verified");
        plots[pid].totalPaymentsUSD = FHE.add(plots[pid].totalPaymentsUSD, plots[pid].annualPaymentUSD);
        _totalForestPayments = FHE.add(_totalForestPayments, plots[pid].annualPaymentUSD);
        FHE.allowThis(plots[pid].totalPaymentsUSD);
        FHE.allow(plots[pid].totalPaymentsUSD, plots[pid].landowner);
        FHE.allowThis(_totalForestPayments);
        emit PaymentMade(pid);
    }

    function allowForestView(address viewer) external onlyOwner {
        FHE.allow(_totalForestCarbon, viewer);
        FHE.allow(_totalForestPayments, viewer);
    }
}
