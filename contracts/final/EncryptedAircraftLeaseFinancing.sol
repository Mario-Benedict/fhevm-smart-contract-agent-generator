// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedAircraftLeaseFinancing
/// @notice Commercial aircraft leasing: encrypted aircraft valuations, lease rates,
///         maintenance reserves, and security deposit management for airlines.
contract EncryptedAircraftLeaseFinancing is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AircraftStatus { Available, Leased, Maintenance, Retired }
    enum LeaseStatus { Proposed, Active, InDefault, Terminated, Returned }

    struct Aircraft {
        string tailNumber;
        string aircraftType;           // e.g. "B737-800"
        string manufacturer;
        uint16 manufactureYear;
        euint64 currentMarketValueUSD; // encrypted current market value
        euint64 maintenanceReserveUSD; // encrypted accumulated maintenance reserve
        euint64 monthlyDepreciation;   // encrypted monthly value decline
        AircraftStatus status;
        address currentLessee;
        uint256 lastAppraisalDate;
    }

    struct LeaseAgreement {
        uint256 aircraftId;
        address lessor;
        address lessee;
        euint64 monthlyRentUSD;        // encrypted monthly rent
        euint64 securityDepositUSD;    // encrypted security deposit
        euint64 maintenanceReserveBps; // encrypted % of rent for maintenance reserve
        euint64 totalRentPaidUSD;      // encrypted cumulative rent paid
        euint64 outstandingArrearsUSD; // encrypted unpaid rent
        uint256 commencementDate;
        uint256 termMonths;
        uint256 terminationDate;
        LeaseStatus status;
        uint8 missedPayments;
    }

    mapping(uint256 => Aircraft) private aircraft;
    mapping(uint256 => LeaseAgreement) private leases;
    mapping(address => bool) public isLessor;
    mapping(address => bool) public isLessee;
    mapping(address => bool) public isAppraiser;
    uint256 public aircraftCount;
    uint256 public leaseCount;
    euint64 private _totalFleetValue;
    euint64 private _totalMonthlyRentRoll;

    event AircraftRegistered(uint256 indexed id, string tailNumber);
    event LeaseProposed(uint256 indexed leaseId, uint256 aircraftId, address lessee);
    event LeaseActivated(uint256 indexed leaseId);
    event RentPaymentReceived(uint256 indexed leaseId);
    event DefaultNotice(uint256 indexed leaseId);
    event LeaseTerminated(uint256 indexed leaseId);
    event AircraftAppraised(uint256 indexed aircraftId);

    modifier onlyLessor() {
        require(isLessor[msg.sender] || msg.sender == owner(), "Not lessor");
        _;
    }

    modifier onlyAppraiser() {
        require(isAppraiser[msg.sender] || msg.sender == owner(), "Not appraiser");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalFleetValue = FHE.asEuint64(0);
        _totalMonthlyRentRoll = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValue);
        FHE.allowThis(_totalMonthlyRentRoll);
        isLessor[msg.sender] = true;
        isAppraiser[msg.sender] = true;
    }

    function addLessor(address l) external onlyOwner { isLessor[l] = true; }
    function addLessee(address l) external onlyOwner { isLessee[l] = true; }
    function addAppraiser(address a) external onlyOwner { isAppraiser[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerAircraft(
        string calldata tailNumber, string calldata aircraftType, string calldata manufacturer,
        uint16 manufactureYear,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encDepreciation, bytes calldata dProof
    ) external onlyLessor whenNotPaused returns (uint256 id) {
        euint64 value = FHE.fromExternal(encValue, vProof);
        euint64 depreciation = FHE.fromExternal(encDepreciation, dProof);
        id = aircraftCount++;
        aircraft[id].tailNumber = tailNumber;
        aircraft[id].aircraftType = aircraftType;
        aircraft[id].manufacturer = manufacturer;
        aircraft[id].manufactureYear = manufactureYear;
        aircraft[id].currentMarketValueUSD = value;
        aircraft[id].maintenanceReserveUSD = FHE.asEuint64(0);
        aircraft[id].monthlyDepreciation = depreciation;
        aircraft[id].status = AircraftStatus.Available;
        aircraft[id].currentLessee = address(0);
        aircraft[id].lastAppraisalDate = block.timestamp;
        _totalFleetValue = FHE.add(_totalFleetValue, value);
        FHE.allowThis(aircraft[id].currentMarketValueUSD);
        FHE.allow(aircraft[id].currentMarketValueUSD, msg.sender);
        FHE.allowThis(aircraft[id].maintenanceReserveUSD);
        FHE.allowThis(aircraft[id].monthlyDepreciation);
        FHE.allowThis(_totalFleetValue);
        emit AircraftRegistered(id, tailNumber);
    }

    function proposeLease(
        uint256 aircraftId,
        address lessee,
        externalEuint64 encMonthlyRent, bytes calldata mrProof,
        externalEuint64 encSecurityDeposit, bytes calldata sdProof,
        externalEuint64 encMaintReserveBps, bytes calldata mrbProof,
        uint256 termMonths_
    ) external onlyLessor whenNotPaused returns (uint256 leaseId) {
        require(aircraft[aircraftId].status == AircraftStatus.Available, "Not available");
        euint64 rent = FHE.fromExternal(encMonthlyRent, mrProof);
        euint64 deposit = FHE.fromExternal(encSecurityDeposit, sdProof);
        euint64 reserveBps = FHE.fromExternal(encMaintReserveBps, mrbProof);
        leaseId = leaseCount++;
        LeaseAgreement storage _s0 = leases[leaseId];
        _s0.aircraftId = aircraftId;
        _s0.lessor = msg.sender;
        _s0.lessee = lessee;
        _s0.monthlyRentUSD = rent;
        _s0.securityDepositUSD = deposit;
        _s0.maintenanceReserveBps = reserveBps;
        _s0.totalRentPaidUSD = FHE.asEuint64(0);
        _s0.outstandingArrearsUSD = FHE.asEuint64(0);
        _s0.commencementDate = block.timestamp;
        _s0.termMonths = termMonths_;
        _s0.terminationDate = block.timestamp + termMonths_ * 30 days;
        _s0.status = LeaseStatus.Proposed;
        _s0.missedPayments = 0;
        FHE.allowThis(leases[leaseId].monthlyRentUSD);
        FHE.allow(leases[leaseId].monthlyRentUSD, lessee);
        FHE.allowThis(leases[leaseId].securityDepositUSD);
        FHE.allow(leases[leaseId].securityDepositUSD, lessee);
        FHE.allowThis(leases[leaseId].maintenanceReserveBps);
        FHE.allowThis(leases[leaseId].totalRentPaidUSD);
        FHE.allowThis(leases[leaseId].outstandingArrearsUSD);
        emit LeaseProposed(leaseId, aircraftId, lessee);
    }

    function activateLease(uint256 leaseId) external onlyLessor {
        LeaseAgreement storage l = leases[leaseId];
        require(l.status == LeaseStatus.Proposed, "Not proposed");
        l.status = LeaseStatus.Active;
        aircraft[l.aircraftId].status = AircraftStatus.Leased;
        aircraft[l.aircraftId].currentLessee = l.lessee;
        _totalMonthlyRentRoll = FHE.add(_totalMonthlyRentRoll, l.monthlyRentUSD);
        FHE.allowThis(_totalMonthlyRentRoll);
        emit LeaseActivated(leaseId);
    }

    function recordRentPayment(
        uint256 leaseId,
        externalEuint64 encPayment, bytes calldata proof
    ) external onlyLessor {
        LeaseAgreement storage l = leases[leaseId];
        require(l.status == LeaseStatus.Active, "Not active");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        euint64 maintReserve = FHE.div(FHE.mul(payment, l.maintenanceReserveBps), 10000);
        l.totalRentPaidUSD = FHE.add(l.totalRentPaidUSD, payment);
        aircraft[l.aircraftId].maintenanceReserveUSD = FHE.add(
            aircraft[l.aircraftId].maintenanceReserveUSD, maintReserve
        );
        FHE.allowThis(l.totalRentPaidUSD);
        FHE.allow(l.totalRentPaidUSD, l.lessee);
        FHE.allowThis(aircraft[l.aircraftId].maintenanceReserveUSD);
        emit RentPaymentReceived(leaseId);
    }

    function recordMissedPayment(uint256 leaseId, externalEuint64 encArrears, bytes calldata proof) external onlyLessor {
        LeaseAgreement storage l = leases[leaseId];
        euint64 arrears = FHE.fromExternal(encArrears, proof);
        l.outstandingArrearsUSD = FHE.add(l.outstandingArrearsUSD, arrears);
        l.missedPayments++;
        FHE.allowThis(l.outstandingArrearsUSD);
        if (l.missedPayments >= 3) {
            l.status = LeaseStatus.InDefault;
            emit DefaultNotice(leaseId);
        }
    }

    function terminateLease(uint256 leaseId) external onlyLessor {
        LeaseAgreement storage l = leases[leaseId];
        l.status = LeaseStatus.Terminated;
        aircraft[l.aircraftId].status = AircraftStatus.Available;
        aircraft[l.aircraftId].currentLessee = address(0);
        ebool _safeSub153 = FHE.ge(_totalMonthlyRentRoll, l.monthlyRentUSD);
        _totalMonthlyRentRoll = FHE.select(_safeSub153, FHE.sub(_totalMonthlyRentRoll, l.monthlyRentUSD), FHE.asEuint64(0));
        FHE.allowThis(_totalMonthlyRentRoll);
        FHE.allow(l.outstandingArrearsUSD, l.lessor);
        emit LeaseTerminated(leaseId);
    }

    function reappraise(
        uint256 aircraftId,
        externalEuint64 encNewValue, bytes calldata proof
    ) external onlyAppraiser {
        euint64 newValue = FHE.fromExternal(encNewValue, proof);
        ebool _safeSub154 = FHE.ge(_totalFleetValue, aircraft[aircraftId].currentMarketValueUSD);
        _totalFleetValue = FHE.select(_safeSub154, FHE.sub(_totalFleetValue, aircraft[aircraftId].currentMarketValueUSD), FHE.asEuint64(0));
        aircraft[aircraftId].currentMarketValueUSD = newValue;
        aircraft[aircraftId].lastAppraisalDate = block.timestamp;
        _totalFleetValue = FHE.add(_totalFleetValue, newValue);
        FHE.allowThis(aircraft[aircraftId].currentMarketValueUSD);
        FHE.allowThis(_totalFleetValue);
        emit AircraftAppraised(aircraftId);
    }

    function allowLeaseDetails(uint256 leaseId, address viewer) external {
        LeaseAgreement storage l = leases[leaseId];
        require(msg.sender == l.lessor || msg.sender == l.lessee || isAppraiser[msg.sender], "Unauthorized");
        FHE.allow(l.monthlyRentUSD, viewer);
        FHE.allow(l.securityDepositUSD, viewer);
        FHE.allow(l.totalRentPaidUSD, viewer);
        FHE.allow(l.outstandingArrearsUSD, viewer);
    }

    function allowFleetStats(address viewer) external onlyOwner {
        FHE.allow(_totalFleetValue, viewer);
        FHE.allow(_totalMonthlyRentRoll, viewer);
    }
}
