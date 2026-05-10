// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedElectionVoterRegistrar
/// @notice Encrypted voter registration: each voter has encrypted eligibility score,
///         district assignment, and voting weight. Admin verifies without revealing data.
contract EncryptedElectionVoterRegistrar is ZamaEthereumConfig, Ownable {
    struct VoterRecord {
        euint8 eligibilityScore;   // encrypted 0-100 eligibility confidence
        euint8 districtId;         // encrypted district assignment
        euint16 votingWeight;      // encrypted weighted vote (e.g. if quadratic)
        uint256 registrationDate;
        bool registered;
        bool flagged;
    }

    struct District {
        string districtName;
        euint32 registeredVoterCount; // encrypted
        euint32 expectedTurnout;      // encrypted
        bool active;
    }

    mapping(address => VoterRecord) private voterRecords;
    mapping(uint256 => District) private districts;
    mapping(address => bool) public isRegistrar;
    mapping(address => bool) public isAuditor;
    uint256 public districtCount;
    euint32 private _totalRegistered;
    euint32 private _totalFlagged;

    event VoterRegistered(address indexed voter);
    event VoterFlagged(address indexed voter);
    event VoterDeregistered(address indexed voter);
    event DistrictCreated(uint256 indexed id, string name);

    modifier onlyRegistrar() {
        require(isRegistrar[msg.sender] || msg.sender == owner(), "Not registrar");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalRegistered = FHE.asEuint32(0);
        _totalFlagged = FHE.asEuint32(0);
        FHE.allowThis(_totalRegistered);
        FHE.allowThis(_totalFlagged);
        isRegistrar[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    function addRegistrar(address r) external onlyOwner { isRegistrar[r] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }

    function createDistrict(string calldata name) external onlyRegistrar returns (uint256 id) {
        id = districtCount++;
        districts[id] = District({
            districtName: name, registeredVoterCount: FHE.asEuint32(0),
            expectedTurnout: FHE.asEuint32(0), active: true
        });
        FHE.allowThis(districts[id].registeredVoterCount);
        FHE.allowThis(districts[id].expectedTurnout);
        emit DistrictCreated(id, name);
    }

    function registerVoter(
        address voter,
        externalEuint8 encEligibilityScore, bytes calldata eProof,
        externalEuint8 encDistrict, bytes calldata dProof,
        externalEuint16 encWeight, bytes calldata wProof
    ) external onlyRegistrar {
        require(!voterRecords[voter].registered, "Already registered");
        euint8 score = FHE.fromExternal(encEligibilityScore, eProof);
        euint8 district = FHE.fromExternal(encDistrict, dProof);
        euint16 weight = FHE.fromExternal(encWeight, wProof);
        voterRecords[voter] = VoterRecord({
            eligibilityScore: score, districtId: district, votingWeight: weight,
            registrationDate: block.timestamp, registered: true, flagged: false
        });
        _totalRegistered = FHE.add(_totalRegistered, FHE.asEuint32(1));
        FHE.allowThis(voterRecords[voter].eligibilityScore);
        FHE.allow(voterRecords[voter].eligibilityScore, voter);
        FHE.allowThis(voterRecords[voter].districtId);
        FHE.allow(voterRecords[voter].districtId, voter);
        FHE.allowThis(voterRecords[voter].votingWeight);
        FHE.allow(voterRecords[voter].votingWeight, voter);
        FHE.allowThis(_totalRegistered);
        emit VoterRegistered(voter);
    }

    function flagVoter(address voter) external onlyRegistrar {
        voterRecords[voter].flagged = true;
        _totalFlagged = FHE.add(_totalFlagged, FHE.asEuint32(1));
        FHE.allowThis(_totalFlagged);
        emit VoterFlagged(voter);
    }

    function deregisterVoter(address voter) external onlyRegistrar {
        require(voterRecords[voter].registered, "Not registered");
        voterRecords[voter].registered = false;
        ebool _safeSub219 = FHE.ge(_totalRegistered, FHE.asEuint32(1));
        _totalRegistered = FHE.select(_safeSub219, FHE.sub(_totalRegistered, FHE.asEuint32(1)), FHE.asEuint32(0));
        FHE.allowThis(_totalRegistered);
        emit VoterDeregistered(voter);
    }

    function verifyEligibility(address voter) external returns (ebool eligible) {
        require(isRegistrar[msg.sender] || isAuditor[msg.sender], "Unauthorized");
        eligible = FHE.ge(voterRecords[voter].eligibilityScore, FHE.asEuint8(70));
        FHE.allow(eligible, msg.sender);
        FHE.allowThis(eligible);
    }

    function allowVoterRecord(address voter, address viewer) external {
        require(isAuditor[msg.sender] || msg.sender == voter, "Unauthorized");
        FHE.allow(voterRecords[voter].eligibilityScore, viewer);
        FHE.allow(voterRecords[voter].districtId, viewer);
        FHE.allow(voterRecords[voter].votingWeight, viewer);
    }

    function allowRegistryStats(address viewer) external {
        require(isAuditor[msg.sender], "Not auditor");
        FHE.allow(_totalRegistered, viewer);
        FHE.allow(_totalFlagged, viewer);
    }
}
