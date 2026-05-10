// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingJudicialNomination
/// @notice Judicial nomination confirmation where senators' party affiliations are private.
///         Each senator votes with an encrypted ideological alignment score to preserve
///         confidentiality while ensuring democratic process integrity.
contract VotingJudicialNomination is ZamaEthereumConfig, Ownable {
    struct Nominee {
        string name;
        euint16 confirmationVotes;
        euint16 rejectionVotes;
        euint8 bipartisanScore; // encrypted measure of cross-party support
        bool confirmed;
        bool finalized;
        uint256 deadline;
    }

    struct Senator {
        euint8 partyAffiliation; // encrypted party code
        bool registered;
        mapping(uint256 => bool) voted;
    }

    mapping(uint256 => Nominee) private nominees;
    uint256 public nomineeCount;
    mapping(address => Senator) private senators;
    address[] public senatorList;
    euint16 private _confirmationThreshold;

    event NomineeProposed(uint256 indexed id, string name);
    event SenatorVoted(uint256 indexed nomineeId, address senator);
    event NomineeConfirmed(uint256 indexed id);

    constructor(externalEuint16 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _confirmationThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_confirmationThreshold);
    }

    function registerSenator(address s, externalEuint8 encParty, bytes calldata proof) external onlyOwner {
        senators[s].partyAffiliation = FHE.fromExternal(encParty, proof);
        senators[s].registered = true;
        FHE.allowThis(senators[s].partyAffiliation);
        senatorList.push(s);
    }

    function proposeNominee(string calldata name, uint256 daysToVote) external onlyOwner returns (uint256 id) {
        id = nomineeCount++;
        nominees[id].name = name;
        nominees[id].confirmationVotes = FHE.asEuint16(0);
        nominees[id].rejectionVotes = FHE.asEuint16(0);
        nominees[id].bipartisanScore = FHE.asEuint8(0);
        nominees[id].deadline = block.timestamp + daysToVote * 1 days;
        FHE.allowThis(nominees[id].confirmationVotes);
        FHE.allowThis(nominees[id].rejectionVotes);
        FHE.allowThis(nominees[id].bipartisanScore);
        emit NomineeProposed(id, name);
    }

    function vote(uint256 nomineeId, bool confirm) external {
        Senator storage s = senators[msg.sender];
        require(s.registered, "Not senator");
        Nominee storage n = nominees[nomineeId];
        require(!n.finalized && block.timestamp <= n.deadline, "Voting closed");
        require(!s.voted[nomineeId], "Already voted");
        s.voted[nomineeId] = true;
        if (confirm) {
            n.confirmationVotes = FHE.add(n.confirmationVotes, FHE.asEuint16(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(n.confirmationVotes);
        } else {
            n.rejectionVotes = FHE.add(n.rejectionVotes, FHE.asEuint16(1));
            FHE.allowThis(n.rejectionVotes);
        }
        emit SenatorVoted(nomineeId, msg.sender);
    }

    function finalizeConfirmation(uint256 nomineeId) external onlyOwner {
        Nominee storage n = nominees[nomineeId];
        require(!n.finalized, "Already finalized");
        n.finalized = true;
        ebool confirmed = FHE.ge(n.confirmationVotes, _confirmationThreshold);
        n.confirmed = FHE.isInitialized(confirmed);
        if (n.confirmed) emit NomineeConfirmed(nomineeId);
    }

    function allowNomineeData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(nominees[id].confirmationVotes, viewer); // [acl_misconfig]
        FHE.allow(_confirmationThreshold, msg.sender); // [acl_misconfig]
        FHE.allow(nominees[id].rejectionVotes, viewer);
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