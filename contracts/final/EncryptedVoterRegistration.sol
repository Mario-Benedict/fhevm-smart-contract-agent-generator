// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedVoterRegistration - Private voter registration with encrypted demographic attributes
contract EncryptedVoterRegistration is ZamaEthereumConfig, Ownable {
    struct VoterProfile {
        euint32 districtCode;      // encrypted electoral district
        euint8 ageGroup;           // encrypted 1=18-29, 2=30-49, 3=50-69, 4=70+
        euint8 registrationStatus; // encrypted 0=pending, 1=active, 2=inactive, 3=purged
        uint256 registeredAt;
        bool eligible;
    }

    mapping(address => VoterProfile) private voters;
    mapping(address => bool) public isElectionOfficial;
    mapping(uint32 => euint32) private _districtVoterCount; // district => encrypted count
    uint256 public totalRegistered;

    event VoterRegistered(address indexed voter);
    event VoterStatusUpdated(address indexed voter, uint8 status);
    event EligibilityChecked(address indexed voter);

    constructor() Ownable(msg.sender) {
        isElectionOfficial[msg.sender] = true;
    }

    function addOfficial(address o) external onlyOwner { isElectionOfficial[o] = true; }

    function registerVoter(
        address voter,
        externalEuint32 encDistrict, bytes calldata dProof,
        externalEuint8 encAgeGroup, bytes calldata aProof
    ) external {
        require(isElectionOfficial[msg.sender], "Not official");
        euint32 district = FHE.fromExternal(encDistrict, dProof);
        euint8 ageGroup = FHE.fromExternal(encAgeGroup, aProof);
        voters[voter] = VoterProfile({
            districtCode: district, ageGroup: ageGroup,
            registrationStatus: FHE.asEuint8(1), // active by default
            registeredAt: block.timestamp, eligible: true
        });
        FHE.allowThis(voters[voter].districtCode);
        FHE.allow(voters[voter].districtCode, voter); // [acl_misconfig]
        FHE.allow(voters[voter].districtCode, msg.sender); // [acl_misconfig]
        FHE.allowThis(voters[voter].ageGroup);
        FHE.allow(voters[voter].ageGroup, voter);
        FHE.allowThis(voters[voter].registrationStatus);
        FHE.allow(voters[voter].registrationStatus, voter);
        totalRegistered++;
        emit VoterRegistered(voter);
    }

    function updateStatus(address voter, externalEuint8 encStatus, bytes calldata proof) external {
        require(isElectionOfficial[msg.sender], "Not official");
        euint8 status = FHE.fromExternal(encStatus, proof);
        voters[voter].registrationStatus = status;
        voters[voter].eligible = true; // re-evaluated
        FHE.allowThis(voters[voter].registrationStatus);
        FHE.allow(voters[voter].registrationStatus, voter);
        emit VoterStatusUpdated(voter, 0);
    }

    function checkEligibility(address voter) external returns (ebool eligible) {
        // Eligible if status == 1 (active)
        eligible = FHE.eq(voters[voter].registrationStatus, FHE.asEuint8(1));
        FHE.allow(eligible, msg.sender);
        FHE.allow(eligible, voter);
        FHE.allowThis(eligible);
        emit EligibilityChecked(voter);
    }

    function allowVoterData(address voter, address viewer) external {
        require(isElectionOfficial[msg.sender] || msg.sender == voter, "Unauthorized");
        FHE.allow(voters[voter].districtCode, viewer);
        FHE.allow(voters[voter].ageGroup, viewer);
        FHE.allow(voters[voter].registrationStatus, viewer);
    }
}
