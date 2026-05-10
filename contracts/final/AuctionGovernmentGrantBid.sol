// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionGovernmentGrantBid
/// @notice Government grant competition where organizations bid for public funding.
///         Financial need scores and project impact scores are encrypted to prevent
///         political bias in the selection process.
contract AuctionGovernmentGrantBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct GrantProgram {
        string programName;
        euint64 totalFunding;
        euint8 minImpactScore;
        euint8 minNeedScore;
        uint256 deadline;
        bool finalized;
        euint64 allocatedFunding;
    }

    struct ApplicationBid {
        euint64 requestedAmount;
        euint8 impactScore;
        euint8 financialNeedScore;
        euint8 implementationScore;
        bool placed;
        bool awarded;
    }

    mapping(uint256 => GrantProgram) private programs;
    uint256 public programCount;
    mapping(uint256 => mapping(address => ApplicationBid)) private applications;
    mapping(uint256 => address[]) private applicants;
    mapping(address => bool) public isRegisteredOrg;

    event ProgramCreated(uint256 indexed id, string name);
    event ApplicationSubmitted(uint256 indexed id, address org);
    event GrantsAwarded(uint256 indexed id);

    constructor() Ownable(msg.sender) {}

    function registerOrg(address org) external onlyOwner { isRegisteredOrg[org] = true; }

    function createProgram(
        string calldata name,
        externalEuint64 encFunding, bytes calldata fProof,
        externalEuint8 encMinImpact, bytes calldata iProof,
        externalEuint8 encMinNeed, bytes calldata nProof,
        uint256 deadlineDays
    ) external onlyOwner returns (uint256 id) {
        id = programCount++;
        programs[id].programName = name;
        programs[id].totalFunding = FHE.fromExternal(encFunding, fProof);
        programs[id].minImpactScore = FHE.fromExternal(encMinImpact, iProof);
        programs[id].minNeedScore = FHE.fromExternal(encMinNeed, nProof);
        programs[id].deadline = block.timestamp + deadlineDays * 1 days;
        programs[id].allocatedFunding = FHE.asEuint64(0);
        FHE.allowThis(programs[id].totalFunding);
        FHE.allowThis(programs[id].minImpactScore);
        FHE.allowThis(programs[id].minNeedScore);
        FHE.allowThis(programs[id].allocatedFunding);
        emit ProgramCreated(id, name);
    }

    function submitApplication(
        uint256 programId,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encImpact, bytes calldata iProof,
        externalEuint8 encNeed, bytes calldata nProof,
        externalEuint8 encImpl, bytes calldata mProof
    ) external nonReentrant {
        require(isRegisteredOrg[msg.sender], "Not registered");
        GrantProgram storage gp = programs[programId];
        require(block.timestamp < gp.deadline, "Closed");
        require(!applications[programId][msg.sender].placed, "Already applied");
        applications[programId][msg.sender] = ApplicationBid({
            requestedAmount: FHE.fromExternal(encAmount, aProof),
            impactScore: FHE.fromExternal(encImpact, iProof),
            financialNeedScore: FHE.fromExternal(encNeed, nProof),
            implementationScore: FHE.fromExternal(encImpl, mProof),
            placed: true, awarded: false
        });
        FHE.allowThis(applications[programId][msg.sender].requestedAmount);
        FHE.allowThis(applications[programId][msg.sender].impactScore);
        FHE.allowThis(applications[programId][msg.sender].financialNeedScore);
        FHE.allowThis(applications[programId][msg.sender].implementationScore);
        applicants[programId].push(msg.sender);
        emit ApplicationSubmitted(programId, msg.sender);
    }

    function processGrants(uint256 programId) external onlyOwner nonReentrant {
        GrantProgram storage gp = programs[programId];
        require(block.timestamp >= gp.deadline && !gp.finalized, "Cannot process");
        gp.finalized = true;
        euint64 remaining = gp.totalFunding;
        address[] storage apps = applicants[programId];
        for (uint256 i = 0; i < apps.length; i++) {
            ApplicationBid storage app = applications[programId][apps[i]];
            ebool impactOk = FHE.ge(app.impactScore, gp.minImpactScore);
            ebool needOk = FHE.ge(app.financialNeedScore, gp.minNeedScore);
            ebool valid = FHE.and(impactOk, needOk);
            ebool hasFunds = FHE.ge(remaining, app.requestedAmount);
            ebool award = FHE.and(valid, hasFunds);
            euint64 granted = FHE.select(award, app.requestedAmount, FHE.asEuint64(0));
            ebool _safeSub5 = FHE.ge(remaining, granted);
            remaining = FHE.select(_safeSub5, FHE.sub(remaining, granted), FHE.asEuint64(0));
            gp.allocatedFunding = FHE.add(gp.allocatedFunding, granted);
            app.awarded = FHE.isInitialized(award);
            FHE.allowThis(remaining);
            FHE.allowThis(gp.allocatedFunding);
            FHE.allow(granted, apps[i]);
        }
        emit GrantsAwarded(programId);
    }
}
