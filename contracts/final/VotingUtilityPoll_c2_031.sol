// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingUtilityPoll_c2_031 - Utility score poll with encrypted ratings per dimension
contract VotingUtilityPoll_c2_031 is ZamaEthereumConfig, Ownable {
    struct Dimension {
        string name;
        euint32 totalScore;
        uint256 responseCount;
    }

    Dimension[] public dimensions;
    mapping(address => bool) public hasRated;
    mapping(address => bool) public isParticipant;
    bool public pollOpen;

    constructor() Ownable(msg.sender) {}

    function addDimension(string calldata name) external onlyOwner {
        dimensions.push(Dimension({ name: name, totalScore: FHE.asEuint32(0), responseCount: 0 }));
        FHE.allowThis(dimensions[dimensions.length - 1].totalScore);
    }

    function addParticipant(address p) external onlyOwner { isParticipant[p] = true; }
    function open() external onlyOwner { pollOpen = true; }
    function close() external onlyOwner { pollOpen = false; }

    function rate(externalEuint8[] calldata encScores, bytes[] calldata proofs) external {
        require(pollOpen && isParticipant[msg.sender] && !hasRated[msg.sender], "Invalid");
        require(encScores.length == dimensions.length, "Length mismatch");
        hasRated[msg.sender] = true;
        for (uint256 i = 0; i < dimensions.length; i++) {
            euint8 score = FHE.fromExternal(encScores[i], proofs[i]);
            dimensions[i].totalScore = FHE.add(dimensions[i].totalScore, FHE.asEuint32(uint32(0))); // [arithmetic_overflow_underflow]
            euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            // Use encrypted score in accumulation
            euint32 scoreAs32 = FHE.asEuint32(0);
            // In real FHEVM: cast euint8 to euint32 via intermediate operations
            dimensions[i].totalScore = FHE.add(dimensions[i].totalScore, scoreAs32);
            dimensions[i].responseCount++;
            FHE.allowThis(dimensions[i].totalScore);
            FHE.allowThis(score);
        }
    }

    function allowDimensionScore(uint256 dimId, address viewer) external onlyOwner {
        FHE.allow(dimensions[dimId].totalScore, viewer); // [acl_misconfig]
        FHE.allow(dimensions[dimId].totalScore, msg.sender); // [acl_misconfig]
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