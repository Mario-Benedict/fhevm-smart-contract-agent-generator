// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedAircraftLeasePortfolio
/// @notice Aviation lease portfolio: encrypted monthly lease rates, encrypted aircraft residual values,
///         encrypted maintenance reserve accounts, and private lessee creditworthiness scoring.
contract EncryptedAircraftLeasePortfolio is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum AircraftType { NARROWBODY, WIDEBODY, REGIONAL_JET, TURBOPROP, FREIGHTER, HELICOPTER }

    struct Aircraft {
        string tailNumber;
        string model;
        AircraftType aircraftType;
        address currentLessee;
        euint64 currentLeaseRateUSD; // encrypted monthly lease rate
        euint64 residualValueUSD;    // encrypted residual value
        euint64 maintenanceReserve;  // encrypted maintenance reserve balance
        euint64 lessorBookValue;     // encrypted book value on lessor balance sheet
        euint64 creditScoreLessee;   // encrypted lessee creditworthiness
        uint256 deliveryDate;
        uint256 leaseEnd;
        bool onLease;
        bool inMaintenance;
    }

    struct LeaseContract {
        uint256 aircraftId;
        address lessee;
        euint64 monthlyRateUSD;       // encrypted contractual monthly rate
        euint64 securityDepositUSD;   // encrypted security deposit
        euint64 maintenanceReserveBps;// encrypted % of payment to maintenance reserve
        euint64 totalPaymentsReceived;// encrypted lifetime payments
        euint64 arrearsUSD;           // encrypted outstanding arrears
        uint256 leaseStart;
        uint256 leaseEnd;
        bool defaulted;
        bool active;
    }

    mapping(uint256 => Aircraft) private fleet;
    mapping(uint256 => LeaseContract) private contracts;
    uint256 public fleetSize;
    uint256 public contractCount;
    euint64 private _totalFleetValue;
    euint64 private _totalMaintenanceReserves;
    euint64 private _monthlyLeaseIncome;
    mapping(address => bool) public isLeaseManager;

    event AircraftAdded(uint256 indexed id, string tail, AircraftType aType);
    event LeaseExecuted(uint256 indexed contractId, uint256 aircraftId, address lessee);
    event LeasePaymentReceived(uint256 indexed contractId);
    event DefaultNoticed(uint256 indexed contractId);
    event AircraftReturned(uint256 indexed aircraftId);

    constructor() Ownable(msg.sender) {
        _totalFleetValue = FHE.asEuint64(0);
        _totalMaintenanceReserves = FHE.asEuint64(0);
        _monthlyLeaseIncome = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetValue);
        FHE.allowThis(_totalMaintenanceReserves);
        FHE.allowThis(_monthlyLeaseIncome);
        isLeaseManager[msg.sender] = true;
    }

    function addLeaseManager(address lm) external onlyOwner { isLeaseManager[lm] = true; }

    function addAircraft(
        string calldata tail, string calldata model, AircraftType aType,
        externalEuint64 encBookValue, bytes calldata bProof,
        externalEuint64 encResidual, bytes calldata rProof
    ) external returns (uint256 id) {
        require(isLeaseManager[msg.sender], "Not manager");
        euint64 book = FHE.fromExternal(encBookValue, bProof);
        euint64 residual = FHE.fromExternal(encResidual, rProof);
        id = fleetSize++;
        fleet[id] = Aircraft({
            tailNumber: tail, model: model, aircraftType: aType,
            currentLessee: address(0), currentLeaseRateUSD: FHE.asEuint64(0),
            residualValueUSD: residual, maintenanceReserve: FHE.asEuint64(0),
            lessorBookValue: book, creditScoreLessee: FHE.asEuint64(0),
            deliveryDate: 0, leaseEnd: 0, onLease: false, inMaintenance: false
        });
        _totalFleetValue = FHE.add(_totalFleetValue, book);
        FHE.allowThis(fleet[id].residualValueUSD);
        FHE.allowThis(fleet[id].maintenanceReserve);
        FHE.allowThis(fleet[id].lessorBookValue);
        FHE.allowThis(fleet[id].currentLeaseRateUSD);
        FHE.allowThis(fleet[id].creditScoreLessee);
        FHE.allowThis(_totalFleetValue);
        emit AircraftAdded(id, tail, aType);
    }

    function executeLease(
        uint256 aircraftId, address lessee,
        externalEuint64 encMonthlyRate, bytes calldata mrProof,
        externalEuint64 encDeposit, bytes calldata dProof,
        externalEuint64 encMaintReserveBps, bytes calldata mrbProof,
        externalEuint64 encCreditScore, bytes calldata csProof,
        uint256 leaseStart, uint256 leaseEnd
    ) external returns (uint256 contractId) {
        require(isLeaseManager[msg.sender], "Not manager");
        Aircraft storage ac = fleet[aircraftId];
        require(!ac.onLease && !ac.inMaintenance, "Aircraft unavailable");
        euint64 rate = FHE.fromExternal(encMonthlyRate, mrProof);
        euint64 deposit = FHE.fromExternal(encDeposit, dProof);
        euint64 maintBps = FHE.fromExternal(encMaintReserveBps, mrbProof);
        euint64 credit = FHE.fromExternal(encCreditScore, csProof);
        contractId = contractCount++;
        contracts[contractId] = LeaseContract({
            aircraftId: aircraftId, lessee: lessee,
            monthlyRateUSD: rate, securityDepositUSD: deposit,
            maintenanceReserveBps: maintBps, totalPaymentsReceived: FHE.asEuint64(0),
            arrearsUSD: FHE.asEuint64(0), leaseStart: leaseStart, leaseEnd: leaseEnd,
            defaulted: false, active: true
        });
        ac.currentLessee = lessee;
        ac.currentLeaseRateUSD = rate;
        ac.creditScoreLessee = credit;
        ac.onLease = true;
        ac.deliveryDate = leaseStart;
        ac.leaseEnd = leaseEnd;
        _monthlyLeaseIncome = FHE.add(_monthlyLeaseIncome, rate);
        FHE.allowThis(contracts[contractId].monthlyRateUSD);
        FHE.allowThis(contracts[contractId].securityDepositUSD);
        FHE.allowThis(contracts[contractId].maintenanceReserveBps);
        FHE.allowThis(contracts[contractId].totalPaymentsReceived);
        FHE.allowThis(contracts[contractId].arrearsUSD);
        FHE.allow(contracts[contractId].monthlyRateUSD, lessee);
        FHE.allowThis(ac.currentLeaseRateUSD);
        FHE.allowThis(ac.creditScoreLessee);
        FHE.allowThis(_monthlyLeaseIncome);
        emit LeaseExecuted(contractId, aircraftId, lessee);
    }

    function receivePayment(uint256 contractId, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        LeaseContract storage lc = contracts[contractId];
        require(lc.lessee == msg.sender && lc.active, "Not lessee");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        // Allocate maintenance reserve
        euint64 maintReserve = FHE.div(FHE.mul(amount, lc.maintenanceReserveBps), 10000);
        euint64 netPayment = FHE.sub(amount, maintReserve);
        lc.totalPaymentsReceived = FHE.add(lc.totalPaymentsReceived, netPayment);
        fleet[lc.aircraftId].maintenanceReserve = FHE.add(fleet[lc.aircraftId].maintenanceReserve, maintReserve);
        _totalMaintenanceReserves = FHE.add(_totalMaintenanceReserves, maintReserve);
        // Clear arrears
        ebool clearsArrears = FHE.ge(netPayment, lc.arrearsUSD);
        lc.arrearsUSD = FHE.select(clearsArrears, FHE.asEuint64(0), FHE.sub(lc.arrearsUSD, netPayment));
        FHE.allowThis(lc.totalPaymentsReceived);
        FHE.allow(lc.totalPaymentsReceived, msg.sender);
        FHE.allowThis(lc.arrearsUSD);
        FHE.allow(lc.arrearsUSD, msg.sender);
        FHE.allowThis(fleet[lc.aircraftId].maintenanceReserve);
        FHE.allowThis(_totalMaintenanceReserves);
        emit LeasePaymentReceived(contractId);
    }

    function noticeDefault(uint256 contractId, externalEuint64 encArrears, bytes calldata proof) external {
        require(isLeaseManager[msg.sender], "Not manager");
        euint64 arrears = FHE.fromExternal(encArrears, proof);
        contracts[contractId].arrearsUSD = FHE.add(contracts[contractId].arrearsUSD, arrears);
        contracts[contractId].defaulted = true;
        FHE.allowThis(contracts[contractId].arrearsUSD);
        emit DefaultNoticed(contractId);
    }

    function returnAircraft(uint256 aircraftId) external {
        require(isLeaseManager[msg.sender], "Not manager");
        Aircraft storage ac = fleet[aircraftId];
        ac.onLease = false;
        ac.currentLessee = address(0);
        _monthlyLeaseIncome = FHE.sub(_monthlyLeaseIncome, ac.currentLeaseRateUSD);
        ac.currentLeaseRateUSD = FHE.asEuint64(0);
        FHE.allowThis(ac.currentLeaseRateUSD);
        FHE.allowThis(_monthlyLeaseIncome);
        emit AircraftReturned(aircraftId);
    }
}
