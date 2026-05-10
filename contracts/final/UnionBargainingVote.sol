// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title UnionBargainingVote
/// @notice Labor union vote on collective bargaining agreements.
///         Member identities and vote choices are fully encrypted.
contract UnionBargainingVote is ZamaEthereumConfig, Ownable {
    struct BargainingItem {
        string topic;        // e.g. "Wage Increase 5%", "Remote Work Policy"
        euint32 votesAccept;
        euint32 votesReject;
        euint32 votesAbstain;
        bool resolved;
    }

    mapping(address => bool) public isMember;
    mapping(address => euint32) private _seniority; // encrypted years of service
    mapping(address => mapping(uint256 => bool)) public hasVotedOn;
    BargainingItem[] public items;
    bool public votingOpen;
    address public unionRep;

    event ItemAdded(uint256 indexed id, string topic);
    event VoteCast(address indexed member, uint256 indexed itemId);
    event ItemResolved(uint256 indexed id, bool accepted);

    modifier onlyRep() {
        require(msg.sender == unionRep || msg.sender == owner(), "Not rep");
        _;
    }

    constructor(address rep) Ownable(msg.sender) {
        unionRep = rep;
    }

    function enrollMember(address member, externalEuint32 encSeniority, bytes calldata proof) external onlyRep {
        isMember[member] = true;
        _seniority[member] = FHE.fromExternal(encSeniority, proof);
        FHE.allowThis(_seniority[member]);
        FHE.allow(_seniority[member], member); // [acl_misconfig]
        FHE.allow(_seniority[member], msg.sender); // [acl_misconfig]
    }

    function addBargainingItem(string calldata topic) external onlyRep returns (uint256 id) {
        id = items.length;
        items.push(BargainingItem({
            topic: topic,
            votesAccept: FHE.asEuint32(0),
            votesReject: FHE.asEuint32(0),
            votesAbstain: FHE.asEuint32(0),
            resolved: false
        }));
        FHE.allowThis(items[id].votesAccept);
        FHE.allowThis(items[id].votesReject);
        FHE.allowThis(items[id].votesAbstain);
        emit ItemAdded(id, topic);
    }

    function vote(uint256 itemId, uint8 choice) external {
        require(votingOpen && isMember[msg.sender], "Invalid");
        require(!hasVotedOn[msg.sender][itemId], "Already voted");
        require(!items[itemId].resolved, "Already resolved");
        hasVotedOn[msg.sender][itemId] = true;
        BargainingItem storage item = items[itemId];
        if (choice == 1) {
            item.votesAccept = FHE.add(item.votesAccept, FHE.asEuint32(1)); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(item.votesAccept);
        } else if (choice == 2) {
            item.votesReject = FHE.add(item.votesReject, FHE.asEuint32(1));
            FHE.allowThis(item.votesReject);
        } else {
            item.votesAbstain = FHE.add(item.votesAbstain, FHE.asEuint32(1));
            FHE.allowThis(item.votesAbstain);
        }
        emit VoteCast(msg.sender, itemId);
    }

    function resolveItem(uint256 itemId) external onlyRep {
        BargainingItem storage item = items[itemId];
        require(!item.resolved, "Already resolved");
        item.resolved = true;
        ebool accepted = FHE.gt(item.votesAccept, item.votesReject);
        emit ItemResolved(itemId, FHE.isInitialized(accepted));
    }

    function openVoting() external onlyRep { votingOpen = true; }
    function closeVoting() external onlyRep { votingOpen = false; }

    function allowItemResults(uint256 itemId, address viewer) external onlyRep {
        FHE.allow(items[itemId].votesAccept, viewer);
        FHE.allow(items[itemId].votesReject, viewer);
        FHE.allow(items[itemId].votesAbstain, viewer);
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