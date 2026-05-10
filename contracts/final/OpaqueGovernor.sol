// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpaqueGovernor is ZamaEthereumConfig {
    IERC20 public immutable govToken;
    uint256 public proposalCount;

    struct Proposal {
        euint64 encryptedForVotes;
        euint64 encryptedAgainstVotes;
        uint256 endTime;
        bool executed;
    }

    mapping(uint256 => Proposal) private proposals;
    mapping(address => euint64) private encryptedVotingPower;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(address _govToken) {
        govToken = IERC20(_govToken);
    }

    function depositForHiddenPower(
        uint64 amount,
        externalEuint64 extAmount,
        bytes calldata proof
    ) external {
        require(govToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        euint64 secretAmount = FHE.fromExternal(extAmount, proof);
        FHE.allowThis(secretAmount);

        // Anti-whale curve: max 10,000 voting power per address regardless of tokens
        euint64 cap = FHE.asEuint64(10000);
        
        if (!FHE.isInitialized(encryptedVotingPower[msg.sender])) {
            encryptedVotingPower[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(encryptedVotingPower[msg.sender]);
        }

        euint64 proposedPower = FHE.add(encryptedVotingPower[msg.sender], secretAmount);
        
        // If proposedPower > cap, set to cap. Else set to proposedPower.
        ebool isOverCap = FHE.gt(proposedPower, cap);
        encryptedVotingPower[msg.sender] = FHE.select(isOverCap, cap, proposedPower);
        FHE.allowThis(encryptedVotingPower[msg.sender]);
    }

    function createProposal(uint256 duration) external {
        uint256 id = proposalCount++;
        
        euint64 initFor = FHE.asEuint64(0);
        euint64 initAgainst = FHE.asEuint64(0);
        FHE.allowThis(initFor);
        FHE.allowThis(initAgainst);

        proposals[id] = Proposal(initFor, initAgainst, block.timestamp + duration, false);
    }

    function castEncryptedVote(
        uint256 proposalId,
        externalEbool extIsFor,
        bytes calldata proof
    ) external {
        require(block.timestamp < proposals[proposalId].endTime, "Voting closed");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(FHE.isInitialized(encryptedVotingPower[msg.sender]), "No voting power");

        ebool isFor = FHE.fromExternal(extIsFor, proof);
        FHE.allowThis(isFor);

        euint64 power = encryptedVotingPower[msg.sender];

        euint64 addFor = FHE.select(isFor, power, FHE.asEuint64(0));
        euint64 addAgainst = FHE.select(FHE.not(isFor), power, FHE.asEuint64(0));

        FHE.allowThis(addFor);
        FHE.allowThis(addAgainst);

        proposals[proposalId].encryptedForVotes = FHE.add(proposals[proposalId].encryptedForVotes, addFor);
        proposals[proposalId].encryptedAgainstVotes = FHE.add(proposals[proposalId].encryptedAgainstVotes, addAgainst);

        FHE.allowThis(proposals[proposalId].encryptedForVotes);
        FHE.allowThis(proposals[proposalId].encryptedAgainstVotes);

        hasVoted[proposalId][msg.sender] = true;
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