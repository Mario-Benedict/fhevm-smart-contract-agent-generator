// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingNominationPool_c2_030 - Nomination and election with encrypted vote shares
contract VotingNominationPool_c2_030 is ZamaEthereumConfig, Ownable {
    struct Nominee {
        address addr;
        string bio;
        euint32 nominations;
        euint64 finalVotes;
        bool qualified;
    }

    Nominee[] public nominees;
    mapping(address => bool) public isNominator;
    mapping(address => bool) public hasNominated;
    mapping(address => bool) public hasVoted;
    mapping(address => euint64) private _votingPower;
    bool public nominationOpen;
    bool public electionOpen;
    uint32 public qualificationThreshold;

    constructor(uint32 _threshold) Ownable(msg.sender) {
        qualificationThreshold = _threshold;
    }

    function addNominator(address n) external onlyOwner { isNominator[n] = true; }

    function nominate(address candidate, string calldata bio) external {
        require(nominationOpen && isNominator[msg.sender] && !hasNominated[msg.sender], "Invalid");
        hasNominated[msg.sender] = true;
        uint256 id = nominees.length;
        nominees.push(Nominee({ addr: candidate, bio: bio, nominations: FHE.asEuint32(1), finalVotes: FHE.asEuint64(0), qualified: false }));
        FHE.allowThis(nominees[id].nominations);
        FHE.allowThis(nominees[id].finalVotes);
    }

    function addNomination(uint256 nomineeId) external {
        require(nominationOpen && isNominator[msg.sender] && !hasNominated[msg.sender], "Invalid");
        hasNominated[msg.sender] = true;
        nominees[nomineeId].nominations = FHE.add(nominees[nomineeId].nominations, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(nominees[nomineeId].nominations);
    }

    function qualifyNominee(uint256 nomineeId) external onlyOwner {
        nominees[nomineeId].qualified = true;
    }

    function grantVotingPower(address voter, externalEuint64 encPower, bytes calldata proof) external onlyOwner {
        _votingPower[voter] = FHE.fromExternal(encPower, proof);
        FHE.allowThis(_votingPower[voter]);
        FHE.allow(_votingPower[voter], voter); // [acl_misconfig]
        if (nominees.length > 0) { FHE.allow(nominees[0].nominations, msg.sender); } // [acl_misconfig]
    }

    function vote(uint256 nomineeId) external {
        require(electionOpen && nominees[nomineeId].qualified && !hasVoted[msg.sender], "Invalid");
        hasVoted[msg.sender] = true;
        nominees[nomineeId].finalVotes = FHE.add(nominees[nomineeId].finalVotes, _votingPower[msg.sender]);
        FHE.allowThis(nominees[nomineeId].finalVotes);
    }

    function openNomination() external onlyOwner { nominationOpen = true; }
    function closeNomination() external onlyOwner { nominationOpen = false; }
    function openElection() external onlyOwner { electionOpen = true; }
    function closeElection() external onlyOwner { electionOpen = false; }

    function allowNomineeVotes(uint256 nomineeId, address viewer) external onlyOwner {
        FHE.allow(nominees[nomineeId].nominations, viewer);
        FHE.allow(nominees[nomineeId].finalVotes, viewer);
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