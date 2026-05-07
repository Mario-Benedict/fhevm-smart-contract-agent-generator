// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TrustlessAuditLogging is ZamaEthereumConfig, Ownable {
    mapping(uint256 => euint64) public auditHashes; // FHE packed representations
    mapping(uint256 => ebool) public auditFlags; // True if error found
    mapping(address => euint64) public auditorReputation;
    uint256 public logCount;

    constructor() Ownable(msg.sender) {}

    function submitAuditLog(externalEuint64 logHashStr, externalEbool flagStr, bytes calldata proofH, bytes calldata proofF) public {
        euint64 hash = FHE.fromExternal(logHashStr, proofH);
        ebool flag = FHE.fromExternal(flagStr, proofF);

        auditHashes[logCount] = hash;
        auditFlags[logCount] = flag;
        
        // Auditor gains 10 hidden reputation points per valid submitted log
        auditorReputation[msg.sender] = FHE.add(auditorReputation[msg.sender], FHE.asEuint64(10));
        
        FHE.allowThis(auditHashes[logCount]);
        FHE.allowThis(auditFlags[logCount]);
        FHE.allowThis(auditorReputation[msg.sender]);

        logCount++;
    }

    function checkCompliance(uint256 logId) public returns (ebool) {
        // True if no error found (flag is false)
        ebool compliant = FHE.not(auditFlags[logId]);
        return compliant;
    }
}
