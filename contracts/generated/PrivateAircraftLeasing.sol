// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateAircraftLeasing
/// @notice Commercial aircraft leasing with encrypted lease rates, maintenance costs,
///         and encrypted utilization hours. Lessor tracks fleet anonymously.
contract PrivateAircraftLeasing is ZamaEthereumConfig, Ownable {
    struct Aircraft {
        string tailNumber;
        string model;
        address lessor;
        address lessee;
        euint64 monthlyLeaseUSD;     // encrypted monthly rate
        euint64 maintenanceReserve;  // encrypted reserve per flight hour
        euint32 flightHoursUsed;     // encrypted total hours flown
        euint32 contractedHours;     // encrypted hours contracted
        uint256 leaseStart;
        uint256 leaseEnd;
        bool onLease;
    }

    mapping(uint256 => Aircraft) private fleet;
    mapping(address => bool) public isAircraftOperator;
    uint256 public aircraftCount;
    euint64 private _totalFleetRevenue;
    euint64 private _totalMaintenanceLiability;

    event AircraftAdded(uint256 indexed id, string tail);
    event LeaseSigned(uint256 indexed id, address lessee);
    event FlightHoursLogged(uint256 indexed id);
    event LeaseTerminated(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalFleetRevenue = FHE.asEuint64(0);
        _totalMaintenanceLiability = FHE.asEuint64(0);
        FHE.allowThis(_totalFleetRevenue);
        FHE.allowThis(_totalMaintenanceLiability);
        isAircraftOperator[msg.sender] = true;
    }

    function addOperator(address op) external onlyOwner { isAircraftOperator[op] = true; }

    function addAircraft(
        string calldata tail, string calldata model,
        externalEuint64 encMonthlyRate, bytes calldata rProof,
        externalEuint64 encMaintReserve, bytes calldata mProof
    ) external returns (uint256 id) {
        require(isAircraftOperator[msg.sender], "Not operator");
        euint64 rate = FHE.fromExternal(encMonthlyRate, rProof);
        euint64 reserve = FHE.fromExternal(encMaintReserve, mProof);
        id = aircraftCount++;
        fleet[id] = Aircraft({
            tailNumber: tail, model: model, lessor: msg.sender, lessee: address(0),
            monthlyLeaseUSD: rate, maintenanceReserve: reserve,
            flightHoursUsed: FHE.asEuint32(0), contractedHours: FHE.asEuint32(0),
            leaseStart: 0, leaseEnd: 0, onLease: false
        });
        FHE.allowThis(fleet[id].monthlyLeaseUSD);
        FHE.allow(fleet[id].monthlyLeaseUSD, msg.sender);
        FHE.allowThis(fleet[id].maintenanceReserve);
        FHE.allowThis(fleet[id].flightHoursUsed);
        FHE.allowThis(fleet[id].contractedHours);
        emit AircraftAdded(id, tail);
    }

    function signLease(
        uint256 aircraftId, address lessee,
        externalEuint32 encContractedHours, bytes calldata proof,
        uint256 leaseDays
    ) external {
        require(isAircraftOperator[msg.sender], "Not operator");
        Aircraft storage ac = fleet[aircraftId];
        require(!ac.onLease, "Already on lease");
        euint32 hours_ = FHE.fromExternal(encContractedHours, proof);
        ac.lessee = lessee;
        ac.contractedHours = hours_;
        ac.leaseStart = block.timestamp;
        ac.leaseEnd = block.timestamp + leaseDays * 1 days;
        ac.onLease = true;
        FHE.allowThis(ac.contractedHours);
        FHE.allow(ac.contractedHours, lessee);
        FHE.allow(ac.monthlyLeaseUSD, lessee);
        _totalFleetRevenue = FHE.add(_totalFleetRevenue,
            FHE.mul(ac.monthlyLeaseUSD, FHE.asEuint64(uint64(leaseDays / 30))));
        FHE.allowThis(_totalFleetRevenue);
        emit LeaseSigned(aircraftId, lessee);
    }

    function logFlightHours(uint256 aircraftId, externalEuint32 encHours, bytes calldata proof) external {
        require(isAircraftOperator[msg.sender], "Not operator");
        euint32 hours_ = FHE.fromExternal(encHours, proof);
        Aircraft storage ac = fleet[aircraftId];
        ac.flightHoursUsed = FHE.add(ac.flightHoursUsed, hours_);
        // Accrue maintenance reserve liability
        euint64 maintLiability = FHE.mul(ac.maintenanceReserve, FHE.asEuint64(uint64(0)));
        _totalMaintenanceLiability = FHE.add(_totalMaintenanceLiability, maintLiability);
        FHE.allowThis(ac.flightHoursUsed);
        FHE.allow(ac.flightHoursUsed, ac.lessee);
        FHE.allowThis(_totalMaintenanceLiability);
        emit FlightHoursLogged(aircraftId);
    }

    function terminateLease(uint256 aircraftId) external {
        require(isAircraftOperator[msg.sender], "Not operator");
        Aircraft storage ac = fleet[aircraftId];
        require(ac.onLease && block.timestamp >= ac.leaseEnd, "Not expired");
        ac.onLease = false;
        ac.lessee = address(0);
        emit LeaseTerminated(aircraftId);
    }

    function allowAircraftData(uint256 id, address viewer) external {
        require(isAircraftOperator[msg.sender] || fleet[id].lessee == msg.sender, "Unauthorized");
        FHE.allow(fleet[id].monthlyLeaseUSD, viewer);
        FHE.allow(fleet[id].flightHoursUsed, viewer);
        FHE.allow(fleet[id].contractedHours, viewer);
    }

    function allowFleetStats(address viewer) external {
        require(isAircraftOperator[msg.sender], "Not operator");
        FHE.allow(_totalFleetRevenue, viewer);
        FHE.allow(_totalMaintenanceLiability, viewer);
    }
}
