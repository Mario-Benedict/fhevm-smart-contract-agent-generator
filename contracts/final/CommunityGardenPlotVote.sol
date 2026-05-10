// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CommunityGardenPlotVote
/// @notice Neighborhood residents vote for priority access to garden plots.
///         Allocation scored by encrypted participation history.
contract CommunityGardenPlotVote is ZamaEthereumConfig, Ownable {
    struct Plot { string location; bool allocated; address currentHolder; }
    struct Resident {
        euint32 participationScore;
        bool registered;
        bool hasPlot;
    }

    Plot[] public plots;
    mapping(address => Resident) private residents;
    mapping(address => bool) public hasApplied;
    address[] private applicantQueue;
    bool public applicationOpen;

    event PlotAdded(uint256 indexed id);
    event ApplicationSubmitted(address indexed resident);
    event PlotAllocated(uint256 indexed plotId, address holder);

    constructor() Ownable(msg.sender) {}

    function addPlot(string calldata location) external onlyOwner {
        uint256 id = plots.length;
        plots.push(Plot({ location: location, allocated: false, currentHolder: address(0) }));
        emit PlotAdded(id);
    }

    function registerResident(address r, externalEuint32 encScore, bytes calldata proof) external onlyOwner {
        euint32 score = FHE.fromExternal(encScore, proof);
        residents[r] = Resident({ participationScore: score, registered: true, hasPlot: false });
        FHE.allowThis(residents[r].participationScore);
        FHE.allow(residents[r].participationScore, r);
    }

    function openApplications() external onlyOwner { applicationOpen = true; }
    function closeApplications() external onlyOwner { applicationOpen = false; }

    function applyForPlot() external {
        require(applicationOpen && residents[msg.sender].registered, "Invalid");
        require(!hasApplied[msg.sender] && !residents[msg.sender].hasPlot, "Already applied");
        hasApplied[msg.sender] = true;
        applicantQueue.push(msg.sender);
        emit ApplicationSubmitted(msg.sender);
    }

    function increaseParticipation(address r, externalEuint32 encBonus, bytes calldata proof) external onlyOwner {
        euint32 bonus = FHE.fromExternal(encBonus, proof);
        residents[r].participationScore = FHE.add(residents[r].participationScore, bonus);
        FHE.allowThis(residents[r].participationScore);
        FHE.allow(residents[r].participationScore, r);
    }

    function allocatePlot(uint256 plotId, address applicant) external onlyOwner {
        require(!plots[plotId].allocated, "Already allocated");
        require(residents[applicant].registered && hasApplied[applicant] && !residents[applicant].hasPlot, "Invalid");
        plots[plotId].allocated = true;
        plots[plotId].currentHolder = applicant;
        residents[applicant].hasPlot = true;
        emit PlotAllocated(plotId, applicant);
    }

    function allowResidentScore(address viewer) external {
        FHE.allow(residents[msg.sender].participationScore, viewer);
    }
}
