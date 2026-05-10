// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract AnonymousWhistleblowerBounty is ZamaEthereumConfig, AccessControl {
    bytes32 public constant EXAMINER_ROLE = keccak256("EXAMINER_ROLE");
    
    euint64 public rewardPool;
    mapping(uint256 => euint64) public submissionSeverities;
    mapping(uint256 => ebool) public submissionVerified;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        rewardPool = FHE.asEuint64(1000000); // Base bounty pool
        FHE.allowThis(rewardPool);
    }

    function submitTip(uint256 submissionId, externalEuint64 severityStr, bytes calldata proof) public {
        submissionSeverities[submissionId] = FHE.fromExternal(severityStr, proof);
        submissionVerified[submissionId] = FHE.asEbool(false);
        FHE.allowThis(submissionSeverities[submissionId]);
        FHE.allowThis(submissionVerified[submissionId]);
    }

    function verifySubmissions(uint256 submissionId, externalEbool verStr, bytes calldata proof) public onlyRole(EXAMINER_ROLE) {
        submissionVerified[submissionId] = FHE.fromExternal(verStr, proof);
        FHE.allowThis(submissionVerified[submissionId]);
    }

    function claimBounty(uint256 submissionId) public {
        ebool verified = submissionVerified[submissionId];
        euint64 severity = submissionSeverities[submissionId];
        
        // Payout matches severity score conditionally
        euint64 payout = FHE.select(verified, severity, FHE.asEuint64(0));
        ebool _safeSub2 = FHE.ge(rewardPool, payout);
        rewardPool = FHE.select(_safeSub2, FHE.sub(rewardPool, payout), FHE.asEuint64(0)); // Note: Assuming severity <= pool
        
        FHE.allowThis(rewardPool);
    }
}
