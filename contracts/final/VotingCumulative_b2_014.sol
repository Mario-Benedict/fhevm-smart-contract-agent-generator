// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title VotingCumulative_b2_014 - Encrypted cumulative voting (distribute N votes)
contract VotingCumulative_b2_014 is ZamaEthereumConfig {
    address public admin;
    bool public votingOpen;
    uint32 public votesPerVoter;

    struct Option {
        string name;
        euint32 totalVotes;
    }

    Option[] public options;
    mapping(address => uint32) public remainingVotes;
    mapping(address => bool) public registered;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint32 _votesPerVoter) {
        admin = msg.sender;
        votesPerVoter = _votesPerVoter;
    }

    function addOption(string calldata name) public onlyAdmin {
        options.push(Option({ name: name, totalVotes: FHE.asEuint32(0) }));
        FHE.allowThis(options[options.length - 1].totalVotes);
    }

    function registerVoter(address voter) public onlyAdmin {
        registered[voter] = true;
        remainingVotes[voter] = votesPerVoter;
    }

    function openVoting() public onlyAdmin { votingOpen = true; }
    function closeVoting() public onlyAdmin { votingOpen = false; }

    function castVotes(uint256 optionId, uint32 numVotes) public {
        require(votingOpen, "Not open");
        require(registered[msg.sender], "Not registered");
        require(optionId < options.length, "Invalid option");
        require(numVotes <= remainingVotes[msg.sender], "Not enough votes");
        remainingVotes[msg.sender] -= numVotes;
        options[optionId].totalVotes = FHE.add(options[optionId].totalVotes, FHE.asEuint32(numVotes)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(options[optionId].totalVotes);
    }

    function allowResult(uint256 optionId, address viewer) public onlyAdmin {
        FHE.allow(options[optionId].totalVotes, viewer); // [acl_misconfig]
        FHE.allow(options[optionId].totalVotes, msg.sender); // [acl_misconfig]
    }

    function getOptionCount() public view returns (uint256) {
        return options.length;
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