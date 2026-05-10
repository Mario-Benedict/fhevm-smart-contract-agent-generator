// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedReferendumVoting
/// @notice National referendum voting with: encrypted citizen vote weights by region,
///         private turnout tracking, hidden regional breakdowns, and sealed results
///         until official declaration.
contract EncryptedReferendumVoting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ReferendumStatus { Registration, Voting, Counting, Declared }
    enum VoteChoice { Yes, No, Abstain }

    struct Referendum {
        string question;
        string jurisdiction;
        euint64 totalYesWeight;        // encrypted yes votes weighted
        euint64 totalNoWeight;         // encrypted no votes weighted
        euint64 totalAbstainWeight;    // encrypted abstain votes
        euint64 registeredVoterWeight; // encrypted total eligible weight
        uint32  voterCount;
        ReferendumStatus status;
        uint256 registrationEnd;
        uint256 votingEnd;
    }

    struct CitizenVoter {
        euint32 regionCode;            // encrypted region
        euint64 voteWeight;            // encrypted weight
        bool registered;
        bool voted;
    }

    mapping(uint256 => Referendum) private referendums;
    mapping(address => CitizenVoter) private voters;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isElectionCommission;

    uint256 public referendumCount;

    event ReferendumCreated(uint256 indexed id, string question);
    event VoterRegistered(address indexed citizen);
    event VoteCast(uint256 indexed referendumId, address indexed citizen);
    event ResultsDeclared(uint256 indexed referendumId);

    modifier onlyElectionCommission() {
        require(isElectionCommission[msg.sender] || msg.sender == owner(), "Not election commission");
        _;
    }

    constructor() Ownable(msg.sender) {
        isElectionCommission[msg.sender] = true;
    }

    function addElectionCommission(address ec) external onlyOwner { isElectionCommission[ec] = true; }

    function createReferendum(
        string calldata question, string calldata jurisdiction,
        uint256 registrationDays, uint256 votingDays
    ) external onlyElectionCommission returns (uint256 id) {
        id = referendumCount++;
        uint256 regEnd = block.timestamp + registrationDays * 1 days;
        referendums[id].question = question;
        referendums[id].jurisdiction = jurisdiction;
        referendums[id].totalYesWeight = FHE.asEuint64(0);
        referendums[id].totalNoWeight = FHE.asEuint64(0);
        referendums[id].totalAbstainWeight = FHE.asEuint64(0);
        referendums[id].registeredVoterWeight = FHE.asEuint64(0);
        referendums[id].voterCount = 0;
        referendums[id].status = ReferendumStatus.Registration;
        referendums[id].registrationEnd = regEnd;
        referendums[id].votingEnd = regEnd + votingDays * 1 days;
        FHE.allowThis(referendums[id].totalYesWeight);
        FHE.allowThis(referendums[id].totalNoWeight);
        FHE.allowThis(referendums[id].totalAbstainWeight);
        FHE.allowThis(referendums[id].registeredVoterWeight);
        emit ReferendumCreated(id, question);
    }

    function registerVoter(
        address citizen,
        externalEuint32 encRegion, bytes calldata regProof,
        externalEuint64 encWeight, bytes calldata wProof
    ) external onlyElectionCommission {
        euint32 region = FHE.fromExternal(encRegion, regProof);
        euint64 weight = FHE.fromExternal(encWeight, wProof);
        voters[citizen] = CitizenVoter({ regionCode: region, voteWeight: weight, registered: true, voted: false });
        FHE.allowThis(voters[citizen].regionCode);
        FHE.allowThis(voters[citizen].voteWeight); FHE.allow(voters[citizen].voteWeight, citizen); // [acl_misconfig]
        FHE.allow(voters[citizen].regionCode, msg.sender); // [acl_misconfig]
        emit VoterRegistered(citizen);
    }

    function castVote(uint256 referendumId, VoteChoice choice) external nonReentrant {
        Referendum storage r = referendums[referendumId];
        CitizenVoter storage v = voters[msg.sender];
        require(r.status == ReferendumStatus.Voting, "Not voting period");
        require(block.timestamp < r.votingEnd, "Voting ended");
        require(v.registered && !hasVoted[referendumId][msg.sender], "Cannot vote");
        hasVoted[referendumId][msg.sender] = true;
        v.voted = true;
        r.voterCount++;
        if (choice == VoteChoice.Yes) {
            r.totalYesWeight = FHE.add(r.totalYesWeight, v.voteWeight);
            FHE.allowThis(r.totalYesWeight);
        } else if (choice == VoteChoice.No) {
            r.totalNoWeight = FHE.add(r.totalNoWeight, v.voteWeight);
            FHE.allowThis(r.totalNoWeight);
        } else {
            r.totalAbstainWeight = FHE.add(r.totalAbstainWeight, v.voteWeight);
            FHE.allowThis(r.totalAbstainWeight);
        }
        emit VoteCast(referendumId, msg.sender);
    }

    function startVoting(uint256 referendumId) external onlyElectionCommission {
        require(referendums[referendumId].status == ReferendumStatus.Registration, "Wrong state");
        referendums[referendumId].status = ReferendumStatus.Voting;
    }

    function declareResults(uint256 referendumId) external onlyElectionCommission {
        Referendum storage r = referendums[referendumId];
        require(block.timestamp >= r.votingEnd, "Voting not ended");
        r.status = ReferendumStatus.Declared;
        FHE.allow(r.totalYesWeight, owner()); FHE.allow(r.totalNoWeight, owner()); FHE.allow(r.totalAbstainWeight, owner());
        emit ResultsDeclared(referendumId);
    }

    function allowCommissionResults(uint256 refId, address commissioner) external onlyOwner {
        FHE.allow(referendums[refId].totalYesWeight, commissioner);
        FHE.allow(referendums[refId].totalNoWeight, commissioner);
    }
    function getTotalYes(uint256 id) external view returns (euint64) { return referendums[id].totalYesWeight; }
    function getTotalNo(uint256 id) external view returns (euint64) { return referendums[id].totalNoWeight; }
}
