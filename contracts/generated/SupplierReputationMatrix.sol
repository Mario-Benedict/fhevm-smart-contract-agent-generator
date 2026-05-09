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
}