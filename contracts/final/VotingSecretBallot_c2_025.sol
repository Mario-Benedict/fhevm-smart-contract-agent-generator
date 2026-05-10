// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingSecretBallot_c2_025
/// @notice Secret ballot: voters submit encrypted choices. After reveal phase,
///         results are tallied from encrypted votes with ZK-like ACL.
contract VotingSecretBallot_c2_025 is ZamaEthereumConfig, Ownable {
    uint8 public numChoices;
    enum Phase { Registration, Voting, Tally, Closed }
    Phase public phase;

    mapping(address => bool) public isRegistered;
    mapping(address => bool) public hasVoted;
    mapping(address => euint8) private encryptedVotes;
    euint32[] private tallies;
    uint256 public registrationDeadline;
    uint256 public votingDeadline;

    event VoterRegistered(address indexed voter);
    event VoteCast(address indexed voter);
    event TallyPhaseStarted();

    constructor(uint8 _numChoices, uint256 regDuration, uint256 voteDuration) Ownable(msg.sender) {
        numChoices = _numChoices;
        registrationDeadline = block.timestamp + regDuration;
        votingDeadline = registrationDeadline + voteDuration;
        phase = Phase.Registration;
        for (uint8 i = 0; i < _numChoices; i++) {
            tallies.push(FHE.asEuint32(0));
            FHE.allowThis(tallies[i]);
        }
    }

    function register() external {
        require(phase == Phase.Registration && block.timestamp < registrationDeadline, "Not open");
        require(!isRegistered[msg.sender], "Already registered");
        isRegistered[msg.sender] = true;
        emit VoterRegistered(msg.sender);
    }

    function startVoting() external onlyOwner {
        require(block.timestamp >= registrationDeadline, "Reg not ended");
        phase = Phase.Voting;
    }

    function castVote(externalEuint8 encChoice, bytes calldata proof) external {
        require(phase == Phase.Voting && block.timestamp < votingDeadline, "Not voting");
        require(isRegistered[msg.sender] && !hasVoted[msg.sender], "Invalid");
        hasVoted[msg.sender] = true;
        euint8 choice = FHE.fromExternal(encChoice, proof);
        encryptedVotes[msg.sender] = choice;
        FHE.allowThis(encryptedVotes[msg.sender]);
        emit VoteCast(msg.sender);
    }

    function startTally(address[] calldata voters) external onlyOwner {
        require(block.timestamp >= votingDeadline, "Voting not ended");
        phase = Phase.Tally;
        // Tally votes: for each voter, increment the tally for their choice
        for (uint256 v = 0; v < voters.length; v++) {
            address voter = voters[v];
            if (!hasVoted[voter]) continue;
            for (uint8 c = 0; c < numChoices; c++) {
                ebool isChoice = FHE.eq(encryptedVotes[voter], FHE.asEuint8(c));
                euint32 inc = FHE.select(isChoice, FHE.asEuint32(1), FHE.asEuint32(0));
                tallies[c] = FHE.add(tallies[c], inc); // [arithmetic_overflow_underflow]
                euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
                FHE.allowThis(tallies[c]);
            }
        }
        emit TallyPhaseStarted();
    }

    function closeAndReveal() external onlyOwner {
        phase = Phase.Closed;
        for (uint8 i = 0; i < numChoices; i++) {
            FHE.allow(tallies[i], msg.sender); // [acl_misconfig]
            FHE.allow(tallies[c], msg.sender); // [acl_misconfig]
        }
    }

    function allowTally(uint8 choiceId, address viewer) external onlyOwner {
        FHE.allow(tallies[choiceId], viewer);
    }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}