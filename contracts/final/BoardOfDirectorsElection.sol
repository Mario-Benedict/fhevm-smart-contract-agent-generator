// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BoardOfDirectorsElection
/// @notice Confidential corporate board election: institutional shareholders vote
///         with weight proportional to their encrypted shareholdings.
contract BoardOfDirectorsElection is ZamaEthereumConfig, Ownable {
    struct Candidate {
        address addr;
        string name;
        string bio;
        euint64 votesReceived;
        bool qualified;
    }

    mapping(address => euint64) private _shareWeights;
    mapping(address => bool) public isShareholder;
    mapping(address => mapping(uint256 => bool)) public hasVotedForCandidate;
    Candidate[] public candidates;
    bool public electionOpen;
    uint256 public maxVotesPerShareholder; // can vote for N candidates
    address public corporateSecretary;

    event CandidateNominated(uint256 indexed id, address candidate);
    event VoteCast(address indexed shareholder, uint256 indexed candidateId);
    event ElectionClosed();

    modifier onlySecretary() {
        require(msg.sender == corporateSecretary || msg.sender == owner(), "Not secretary");
        _;
    }

    constructor(address secretary, uint256 maxVotes) Ownable(msg.sender) {
        corporateSecretary = secretary;
        maxVotesPerShareholder = maxVotes;
    }

    function registerShareholder(address holder, externalEuint64 encShares, bytes calldata proof) external onlySecretary {
        euint64 shares = FHE.fromExternal(encShares, proof);
        _shareWeights[holder] = shares;
        isShareholder[holder] = true;
        FHE.allowThis(_shareWeights[holder]);
        FHE.allow(_shareWeights[holder], holder);
    }

    function nominateCandidate(address candidate, string calldata name, string calldata bio) external onlySecretary {
        uint256 id = candidates.length;
        candidates.push(Candidate({
            addr: candidate, name: name, bio: bio,
            votesReceived: FHE.asEuint64(0), qualified: true
        }));
        FHE.allowThis(candidates[id].votesReceived);
        emit CandidateNominated(id, candidate);
    }

    function voteForCandidate(uint256 candidateId) external {
        require(electionOpen && isShareholder[msg.sender], "Invalid");
        require(!hasVotedForCandidate[msg.sender][candidateId], "Already voted");
        require(candidates[candidateId].qualified, "Not qualified");
        hasVotedForCandidate[msg.sender][candidateId] = true;
        candidates[candidateId].votesReceived = FHE.add(
            candidates[candidateId].votesReceived,
            _shareWeights[msg.sender]
        );
        FHE.allowThis(candidates[candidateId].votesReceived);
        emit VoteCast(msg.sender, candidateId);
    }

    function disqualifyCandidate(uint256 candidateId) external onlySecretary {
        candidates[candidateId].qualified = false;
    }

    function openElection() external onlySecretary { electionOpen = true; }

    function closeElection() external onlySecretary {
        electionOpen = false;
        emit ElectionClosed();
    }

    function revealResults(address viewer) external onlySecretary {
        for (uint256 i = 0; i < candidates.length; i++) {
            FHE.allow(candidates[i].votesReceived, viewer);
        }
    }

    function allowCandidateVotes(uint256 candidateId, address viewer) external onlySecretary {
        FHE.allow(candidates[candidateId].votesReceived, viewer);
    }
}
