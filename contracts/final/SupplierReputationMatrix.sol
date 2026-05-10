// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract SupplierReputationMatrix is ZamaEthereumConfig {
    struct SupplierIdentity {
        euint16 encryptedScore;
        euint16 hiddenTier; 
        bool isRegistered;
    }

    mapping(address => SupplierIdentity) private suppliers;
    address public auditor;

    modifier onlyAuditor() {
        require(msg.sender == auditor, "Not auditor");
        _;
    }

    constructor() {
        auditor = msg.sender;
    }

    function registerSupplier() external {
        require(!suppliers[msg.sender].isRegistered, "Already registered");
        
        // Initialize with random baseline tier (e.g., 1 to 5) to prevent profiling
        euint64 randomBase = FHE.randEuint64();
        euint64 randomBaseWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 randomBaseExposure = FHE.sub(randomBaseWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint16 initialTier = FHE.asEuint16(FHE.add(FHE.rem(randomBase, 5), FHE.asEuint64(1)));
        
        euint16 initialScore = FHE.asEuint16(0);

        FHE.allowThis(initialTier);
        FHE.allowThis(initialScore);

        suppliers[msg.sender] = SupplierIdentity({
            encryptedScore: initialScore,
            hiddenTier: initialTier,
            isRegistered: true
        });
    }

    function updateEncryptedScore(
        address supplier,
        externalEuint16 extPoints,
        bytes calldata inputProof,
        bool isPenalty
    ) external onlyAuditor {
        require(suppliers[supplier].isRegistered, "Unknown supplier");

        euint16 points = FHE.fromExternal(extPoints, inputProof);



        FHE.allowThis(points);

        euint16 currentScore = suppliers[supplier].encryptedScore;

        if (isPenalty) {
            // Prevent underflow by selecting 0 if points > currentScore
            ebool willUnderflow = FHE.lt(currentScore, points);
            suppliers[supplier].encryptedScore = FHE.select(
                willUnderflow,
                FHE.asEuint16(0),
                FHE.sub(currentScore, points)
            );
        } else {
            suppliers[supplier].encryptedScore = FHE.add(currentScore, points);
        }

        FHE.allowThis(suppliers[supplier].encryptedScore);
    }

    function requestTierView(address supplier) external {
        require(msg.sender == supplier || msg.sender == auditor, "Unauthorized");
        // Allow transient viewing of the hidden tier for a specific transaction
        FHE.allowTransient(suppliers[supplier].hiddenTier, msg.sender);
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