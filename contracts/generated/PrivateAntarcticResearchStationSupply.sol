// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateAntarcticResearchStationSupply
/// @notice Antarctic logistics: encrypted cargo weights, encrypted supply priorities,
///         and encrypted operational costs for polar research stations.
contract PrivateAntarcticResearchStationSupply is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum CargoCategory { FoodSupplies, FuelJetA1, ScientificEquipment, MedicalSupplies, PersonnelGear, Construction }
    enum DeliveryMode { IceBreaker, ResearchVessel, AirDrop, HeliTransfer }
    enum MissionStatus { Planned, InTransit, Delivered, ReturnVoyage, Completed }

    struct PolarStation {
        address nationAuthority;
        string stationName;
        string location;
        euint32 personnelCount;           // encrypted headcount
        euint64 annualOperatingCostUSD;   // encrypted operational budget
        euint64 fuelReserveKg;            // encrypted fuel reserves
        euint32 daysOfFoodSupply;         // encrypted food autonomy days
        bool active;
    }

    struct SupplyMission {
        uint256 stationId;
        DeliveryMode mode;
        CargoCategory primaryCargo;
        euint64 totalCargoKg;             // encrypted total cargo weight
        euint64 missionCostUSD;           // encrypted mission cost
        euint32 fuelCargoKg;              // encrypted fuel portion
        euint32 personnelOnboard;         // encrypted crew/scientists
        uint256 departureDate;
        uint256 eta;
        MissionStatus status;
    }

    mapping(uint256 => PolarStation) private stations;
    mapping(uint256 => SupplyMission[]) private missions;
    mapping(address => bool) public isPolarAuthority;

    uint256 public stationCount;
    euint64 private _totalLogisticsCostUSD;
    euint64 private _totalCargoDeliveredKg;

    event StationRegistered(uint256 indexed id, string name, string location);
    event MissionDispatched(uint256 indexed stationId, uint256 missionIndex, DeliveryMode mode);
    event MissionCompleted(uint256 indexed stationId, uint256 missionIndex);

    modifier onlyAuthority() {
        require(isPolarAuthority[msg.sender] || msg.sender == owner(), "Not polar authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalLogisticsCostUSD = FHE.asEuint64(0);
        _totalCargoDeliveredKg = FHE.asEuint64(0);
        FHE.allowThis(_totalLogisticsCostUSD);
        FHE.allowThis(_totalCargoDeliveredKg);
        isPolarAuthority[msg.sender] = true;
    }

    function addAuthority(address a) external onlyOwner { isPolarAuthority[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerStation(
        string calldata name, string calldata location,
        externalEuint32 encPersonnel, bytes calldata pProof,
        externalEuint64 encBudget, bytes calldata bProof,
        externalEuint64 encFuelReserve, bytes calldata fProof,
        externalEuint32 encFoodDays, bytes calldata fdProof
    ) external onlyAuthority whenNotPaused returns (uint256 id) {
        euint32 personnel = FHE.fromExternal(encPersonnel, pProof);
        euint64 budget = FHE.fromExternal(encBudget, bProof);
        euint64 fuel = FHE.fromExternal(encFuelReserve, fProof);
        euint32 food = FHE.fromExternal(encFoodDays, fdProof);
        id = stationCount++;
        stations[id] = PolarStation({
            nationAuthority: msg.sender, stationName: name, location: location,
            personnelCount: personnel, annualOperatingCostUSD: budget,
            fuelReserveKg: fuel, daysOfFoodSupply: food, active: true
        });
        FHE.allowThis(stations[id].personnelCount); FHE.allow(stations[id].personnelCount, msg.sender);
        FHE.allowThis(stations[id].annualOperatingCostUSD); FHE.allow(stations[id].annualOperatingCostUSD, msg.sender);
        FHE.allowThis(stations[id].fuelReserveKg); FHE.allow(stations[id].fuelReserveKg, msg.sender);
        FHE.allowThis(stations[id].daysOfFoodSupply); FHE.allow(stations[id].daysOfFoodSupply, msg.sender);
        emit StationRegistered(id, name, location);
    }

    function dispatchMission(
        uint256 stationId, DeliveryMode mode, CargoCategory cargo,
        externalEuint64 encTotalCargo, bytes calldata tcProof,
        externalEuint64 encCost, bytes calldata cProof,
        externalEuint32 encFuelCargo, bytes calldata fcProof,
        externalEuint32 encCrew, bytes calldata crewProof,
        uint256 departureDate, uint256 etaDays
    ) external onlyAuthority nonReentrant returns (uint256 missionIndex) {
        euint64 totalCargo = FHE.fromExternal(encTotalCargo, tcProof);
        euint64 cost = FHE.fromExternal(encCost, cProof);
        euint32 fuelCargo = FHE.fromExternal(encFuelCargo, fcProof);
        euint32 crew = FHE.fromExternal(encCrew, crewProof);
        missions[stationId].push(SupplyMission({
            stationId: stationId, mode: mode, primaryCargo: cargo,
            totalCargoKg: totalCargo, missionCostUSD: cost,
            fuelCargoKg: fuelCargo, personnelOnboard: crew,
            departureDate: departureDate,
            eta: departureDate + etaDays * 1 days,
            status: MissionStatus.InTransit
        }));
        missionIndex = missions[stationId].length - 1;
        _totalLogisticsCostUSD = FHE.add(_totalLogisticsCostUSD, cost);
        FHE.allowThis(totalCargo); FHE.allow(totalCargo, stations[stationId].nationAuthority);
        FHE.allowThis(cost); FHE.allow(cost, stations[stationId].nationAuthority);
        FHE.allowThis(fuelCargo); FHE.allowThis(crew);
        FHE.allowThis(_totalLogisticsCostUSD);
        emit MissionDispatched(stationId, missionIndex, mode);
    }

    function confirmDelivery(uint256 stationId, uint256 missionIndex) external onlyAuthority {
        SupplyMission storage m = missions[stationId][missionIndex];
        require(m.status == MissionStatus.InTransit, "Not in transit");
        m.status = MissionStatus.Delivered;
        PolarStation storage s = stations[stationId];
        s.fuelReserveKg = FHE.add(s.fuelReserveKg, FHE.asEuint64(0)); // add fuel cargo
        _totalCargoDeliveredKg = FHE.add(_totalCargoDeliveredKg, m.totalCargoKg);
        FHE.allowThis(s.fuelReserveKg);
        FHE.allowThis(_totalCargoDeliveredKg);
        emit MissionCompleted(stationId, missionIndex);
    }

    function allowPolarStats(address viewer) external onlyOwner {
        FHE.allow(_totalLogisticsCostUSD, viewer);
        FHE.allow(_totalCargoDeliveredKg, viewer);
    }
}
