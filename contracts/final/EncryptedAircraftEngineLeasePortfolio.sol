// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAircraftEngineLeasePortfolio
/// @notice Aviation finance: encrypted engine valuations, maintenance reserves,
///         lease rates, and lessee credit scores managed by an aircraft lessor.
contract EncryptedAircraftEngineLeasePortfolio is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum EngineType { CFM56, GE90, GTFV2500, PW4000, LEAPX }
    enum LeaseStatus { AVAILABLE, ACTIVE, MAINTENANCE, OFF_LEASE, RETURNED }

    struct EngineAsset {
        string serialNumber;
        string aircraftType;
        EngineType engineType;
        euint64 currentMarketValue;  // encrypted appraisal value (USD)
        euint64 maintenanceReserve; // encrypted MR fund balance
        euint64 remainingCycles;    // encrypted EFC (equivalent flight cycles)
        euint32 ageMonths;          // encrypted age in months
        euint32 llpCycleCost;       // encrypted LLP cost per cycle (USD cents)
        uint256 nextShopVisit;      // timestamp
        LeaseStatus status;
        bool airworthinessCurrent;
    }

    struct LeaseAgreement {
        uint256 engineId;
        address lessee;             // airline
        euint64 monthlyLeaseRate;   // encrypted USD/month
        euint64 maintenanceReserveRate; // encrypted USD/cycle accrual
        euint64 securityDeposit;   // encrypted deposit held
        euint64 accruedMR;         // encrypted accrued maintenance reserve
        euint64 totalPaid;         // encrypted total rental payments
        euint32 leaseTerm;         // encrypted term in months
        euint32 monthsPaid;        // encrypted months completed
        uint256 startDate;
        uint256 endDate;
        LeaseStatus status;
    }

    struct AirlineCreditProfile {
        euint32 creditScore;         // encrypted IATA credit score (0-1000)
        euint64 financialStrength;   // encrypted net assets (USD million scaled)
        euint8  routeNetworkScore;   // encrypted route diversity 0-100
        bool approved;
    }

    mapping(uint256 => EngineAsset) private engines;
    mapping(uint256 => LeaseAgreement) private leases;
    mapping(address => AirlineCreditProfile) private airlines;
    mapping(address => bool) public isAppraiser;
    mapping(address => bool) public isCreditAnalyst;
    uint256 public engineCount;
    uint256 public leaseCount;
    euint64 private _portfolioNAV;        // encrypted net asset value
    euint64 private _totalMRFundBalance;  // encrypted total MR collected
    euint64 private _monthlyLeaseRevenue; // encrypted current monthly revenue run-rate

    event EngineAdded(uint256 indexed id, string serialNumber, EngineType eType);
    event LeaseExecuted(uint256 indexed leaseId, uint256 indexed engineId, address indexed lessee);
    event LeaseRentPaid(uint256 indexed leaseId, address indexed lessee);
    event LeaseReturned(uint256 indexed leaseId);
    event MRReimbursed(uint256 indexed leaseId, address indexed lessee);
    event AirlineApproved(address indexed airline);

    constructor() Ownable(msg.sender) {
        _portfolioNAV = FHE.asEuint64(0);
        _totalMRFundBalance = FHE.asEuint64(0);
        _monthlyLeaseRevenue = FHE.asEuint64(0);
        FHE.allowThis(_portfolioNAV);
        FHE.allowThis(_totalMRFundBalance);
        FHE.allowThis(_monthlyLeaseRevenue);
        isAppraiser[msg.sender] = true;
        isCreditAnalyst[msg.sender] = true;
    }

    function addAppraiser(address a) external onlyOwner { isAppraiser[a] = true; }
    function addCreditAnalyst(address a) external onlyOwner { isCreditAnalyst[a] = true; }

    function addEngine(
        string calldata serial,
        string calldata acType,
        EngineType eType,
        externalEuint64 encValue,   bytes calldata vProof,
        externalEuint64 encMR,      bytes calldata mrProof,
        externalEuint64 encCycles,  bytes calldata cProof,
        externalEuint32 encAge,     bytes calldata aProof,
        externalEuint32 encLLPCost, bytes calldata llpProof
    ) external returns (uint256 id) {
        require(isAppraiser[msg.sender], "Not appraiser");
        euint64 value  = FHE.fromExternal(encValue, vProof);
        euint64 mr     = FHE.fromExternal(encMR, mrProof);
        euint64 cycles = FHE.fromExternal(encCycles, cProof);
        euint32 age    = FHE.fromExternal(encAge, aProof);
        euint32 llp    = FHE.fromExternal(encLLPCost, llpProof);
        id = engineCount++;
        engines[id].serialNumber = serial;
        engines[id].aircraftType = acType;
        engines[id].engineType = eType;
        engines[id].currentMarketValue = value;
        engines[id].maintenanceReserve = mr;
        engines[id].remainingCycles = cycles;
        engines[id].ageMonths = age;
        engines[id].llpCycleCost = llp;
        engines[id].nextShopVisit = block.timestamp + 365 days;
        engines[id].status = LeaseStatus.AVAILABLE;
        engines[id].airworthinessCurrent = true;
        _portfolioNAV = FHE.add(_portfolioNAV, value);
        FHE.allowThis(engines[id].currentMarketValue);
        FHE.allowThis(engines[id].maintenanceReserve);
        FHE.allowThis(engines[id].remainingCycles);
        FHE.allowThis(engines[id].ageMonths);
        FHE.allowThis(engines[id].llpCycleCost);
        FHE.allowThis(_portfolioNAV);
        emit EngineAdded(id, serial, eType);
    }

    function approveAirline(
        address airline,
        externalEuint32 encCredit,   bytes calldata crProof,
        externalEuint64 encFinStr,   bytes calldata fsProof,
        externalEuint8  encRoute,    bytes calldata rProof
    ) external {
        require(isCreditAnalyst[msg.sender], "Not analyst");
        euint32 credit = FHE.fromExternal(encCredit, crProof);
        euint64 finStr = FHE.fromExternal(encFinStr, fsProof);
        euint8  route  = FHE.fromExternal(encRoute, rProof);
        airlines[airline] = AirlineCreditProfile({
            creditScore: credit,
            financialStrength: finStr,
            routeNetworkScore: route,
            approved: true
        });
        FHE.allowThis(airlines[airline].creditScore);
        FHE.allow(airlines[airline].creditScore, airline);
        FHE.allowThis(airlines[airline].financialStrength);
        FHE.allowThis(airlines[airline].routeNetworkScore);
        emit AirlineApproved(airline);
    }

    function executeLease(
        uint256 engineId,
        address lessee,
        externalEuint64 encMonthlyRate, bytes calldata mrRProof,
        externalEuint64 encMRRate,      bytes calldata mrrProof,
        externalEuint64 encDeposit,     bytes calldata dProof,
        externalEuint32 encTerm,        bytes calldata tProof
    ) external onlyOwner returns (uint256 leaseId) {
        require(engines[engineId].status == LeaseStatus.AVAILABLE, "Not available");
        require(airlines[lessee].approved, "Airline not approved");
        euint64 mRate  = FHE.fromExternal(encMonthlyRate, mrRProof);
        euint64 mrRate = FHE.fromExternal(encMRRate, mrrProof);
        euint64 dep    = FHE.fromExternal(encDeposit, dProof);
        euint32 term   = FHE.fromExternal(encTerm, tProof);
        leaseId = leaseCount++;
        LeaseAgreement storage _s0 = leases[leaseId];
        _s0.engineId = engineId;
        _s0.lessee = lessee;
        _s0.monthlyLeaseRate = mRate;
        _s0.maintenanceReserveRate = mrRate;
        _s0.securityDeposit = dep;
        _s0.accruedMR = FHE.asEuint64(0);
        _s0.totalPaid = FHE.asEuint64(0);
        _s0.leaseTerm = term;
        _s0.monthsPaid = FHE.asEuint32(0);
        _s0.startDate = block.timestamp;
        _s0.endDate = block.timestamp + 365 days * 3;
        _s0.status = LeaseStatus.ACTIVE;
        engines[engineId].status = LeaseStatus.ACTIVE;
        _monthlyLeaseRevenue = FHE.add(_monthlyLeaseRevenue, mRate);
        FHE.allowThis(leases[leaseId].monthlyLeaseRate);
        FHE.allow(leases[leaseId].monthlyLeaseRate, lessee);
        FHE.allowThis(leases[leaseId].maintenanceReserveRate);
        FHE.allow(leases[leaseId].maintenanceReserveRate, lessee);
        FHE.allowThis(leases[leaseId].securityDeposit);
        FHE.allowThis(leases[leaseId].accruedMR);
        FHE.allowThis(leases[leaseId].totalPaid);
        FHE.allow(leases[leaseId].totalPaid, lessee);
        FHE.allowThis(leases[leaseId].leaseTerm);
        FHE.allow(leases[leaseId].leaseTerm, lessee);
        FHE.allowThis(leases[leaseId].monthsPaid);
        FHE.allowThis(_monthlyLeaseRevenue);
        emit LeaseExecuted(leaseId, engineId, lessee);
    }

    function payMonthlyRent(
        uint256 leaseId,
        externalEuint64 encMRContribution, bytes calldata mrProof
    ) external nonReentrant {
        LeaseAgreement storage lease = leases[leaseId];
        require(lease.lessee == msg.sender, "Not lessee");
        require(lease.status == LeaseStatus.ACTIVE, "Not active");
        euint64 mrContrib = FHE.fromExternal(encMRContribution, mrProof);
        lease.totalPaid = FHE.add(lease.totalPaid, lease.monthlyLeaseRate);
        lease.accruedMR = FHE.add(lease.accruedMR, mrContrib);
        lease.monthsPaid = FHE.add(lease.monthsPaid, FHE.asEuint32(1));
        _totalMRFundBalance = FHE.add(_totalMRFundBalance, mrContrib);
        FHE.allowThis(lease.totalPaid);
        FHE.allow(lease.totalPaid, msg.sender);
        FHE.allowThis(lease.accruedMR);
        FHE.allowThis(lease.monthsPaid);
        FHE.allowThis(_totalMRFundBalance);
        emit LeaseRentPaid(leaseId, msg.sender);
    }

    function returnEngine(uint256 leaseId) external {
        LeaseAgreement storage lease = leases[leaseId];
        require(lease.lessee == msg.sender || msg.sender == owner(), "Unauthorized");
        engines[lease.engineId].status = LeaseStatus.RETURNED;
        lease.status = LeaseStatus.RETURNED;
        emit LeaseReturned(leaseId);
    }

    function reimburseMaintenance(uint256 leaseId, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool sufficient = FHE.ge(leases[leaseId].accruedMR, amount);
        euint64 reimbAmt = FHE.select(sufficient, amount, leases[leaseId].accruedMR);
        ebool _safeSub150 = FHE.ge(leases[leaseId].accruedMR, reimbAmt);
        leases[leaseId].accruedMR = FHE.select(_safeSub150, FHE.sub(leases[leaseId].accruedMR, reimbAmt), FHE.asEuint64(0));
        ebool _safeSub151 = FHE.ge(_totalMRFundBalance, reimbAmt);
        _totalMRFundBalance = FHE.select(_safeSub151, FHE.sub(_totalMRFundBalance, reimbAmt), FHE.asEuint64(0));
        FHE.allowThis(leases[leaseId].accruedMR);
        FHE.allowThis(_totalMRFundBalance);
        emit MRReimbursed(leaseId, leases[leaseId].lessee);
    }

    function updateEngineAppraisal(uint256 engineId, externalEuint64 encNewValue, bytes calldata proof) external {
        require(isAppraiser[msg.sender], "Not appraiser");
        euint64 newVal = FHE.fromExternal(encNewValue, proof);
        ebool _safeSub152 = FHE.ge(_portfolioNAV, engines[engineId].currentMarketValue);
        _portfolioNAV = FHE.select(_safeSub152, FHE.sub(_portfolioNAV, engines[engineId].currentMarketValue), FHE.asEuint64(0));
        engines[engineId].currentMarketValue = newVal;
        _portfolioNAV = FHE.add(_portfolioNAV, newVal);
        FHE.allowThis(engines[engineId].currentMarketValue);
        FHE.allowThis(_portfolioNAV);
    }

    function allowPortfolioView(address investor) external onlyOwner {
        FHE.allow(_portfolioNAV, investor);
        FHE.allow(_totalMRFundBalance, investor);
        FHE.allow(_monthlyLeaseRevenue, investor);
    }
}
