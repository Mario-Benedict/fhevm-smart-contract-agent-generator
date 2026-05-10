// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SupplyChainSourceVote
/// @notice Retailers vote privately on preferred suppliers based on encrypted
///         quality scores, price competitiveness, and sustainability ratings.
contract SupplyChainSourceVote is ZamaEthereumConfig, Ownable {
    struct Supplier {
        string name;
        string country;
        euint16 qualityVoteSum;     // encrypted aggregate quality score
        euint16 priceVoteSum;       // encrypted aggregate price score
        euint16 sustainabilitySum;  // encrypted aggregate sustainability score
        uint32 voteCount;
    }

    Supplier[] public suppliers;
    mapping(address => bool) public isRetailer;
    mapping(address => mapping(uint256 => bool)) public hasEvaluated;
    bool public evaluationOpen;

    event SupplierAdded(uint256 indexed id, string name);
    event EvaluationSubmitted(address indexed retailer, uint256 indexed supplierId);

    constructor() Ownable(msg.sender) {}

    function addSupplier(string calldata name, string calldata country) external onlyOwner returns (uint256 id) {
        id = suppliers.length;
        suppliers.push(Supplier({
            name: name, country: country,
            qualityVoteSum: FHE.asEuint16(0),
            priceVoteSum: FHE.asEuint16(0),
            sustainabilitySum: FHE.asEuint16(0),
            voteCount: 0
        }));
        FHE.allowThis(suppliers[id].qualityVoteSum);
        FHE.allowThis(suppliers[id].priceVoteSum);
        FHE.allowThis(suppliers[id].sustainabilitySum);
        emit SupplierAdded(id, name);
    }

    function addRetailer(address r) external onlyOwner { isRetailer[r] = true; }
    function openEvaluation() external onlyOwner { evaluationOpen = true; }
    function closeEvaluation() external onlyOwner { evaluationOpen = false; }

    function evaluateSupplier(
        uint256 supplierId,
        externalEuint8 encQuality, bytes calldata qProof,
        externalEuint8 encPrice, bytes calldata pProof,
        externalEuint8 encSustain, bytes calldata sProof
    ) external {
        require(evaluationOpen && isRetailer[msg.sender] && !hasEvaluated[msg.sender][supplierId], "Invalid");
        hasEvaluated[msg.sender][supplierId] = true;
        euint8 quality = FHE.fromExternal(encQuality, qProof);
        euint8 price = FHE.fromExternal(encPrice, pProof);
        euint8 sustain = FHE.fromExternal(encSustain, sProof);
        suppliers[supplierId].qualityVoteSum = FHE.add(suppliers[supplierId].qualityVoteSum, FHE.asEuint16(0)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        suppliers[supplierId].priceVoteSum = FHE.add(suppliers[supplierId].priceVoteSum, FHE.asEuint16(0));
        suppliers[supplierId].sustainabilitySum = FHE.add(suppliers[supplierId].sustainabilitySum, FHE.asEuint16(0));
        suppliers[supplierId].voteCount++;
        FHE.allowThis(suppliers[supplierId].qualityVoteSum);
        FHE.allowThis(suppliers[supplierId].priceVoteSum);
        FHE.allowThis(suppliers[supplierId].sustainabilitySum);
        // scores stored for ACL access later
        FHE.allowThis(quality);
        FHE.allowThis(price);
        FHE.allowThis(sustain);
        emit EvaluationSubmitted(msg.sender, supplierId);
    }

    function allowSupplierScores(uint256 supplierId, address viewer) external onlyOwner {
        FHE.allow(suppliers[supplierId].qualityVoteSum, viewer); // [acl_misconfig]
        FHE.allow(suppliers[supplierId].priceVoteSum, msg.sender); // [acl_misconfig]
        FHE.allow(suppliers[supplierId].priceVoteSum, viewer);
        FHE.allow(suppliers[supplierId].sustainabilitySum, viewer);
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