// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SecureMedicalResearchData is ZamaEthereumConfig, Ownable {
    euint64 public totalAgeAggregated;
    euint64 public totalWeightAggregated;
    euint64 public participantCount;
    
    mapping(address => ebool) public hasParticipated;

    constructor() Ownable(msg.sender) {
        totalAgeAggregated = FHE.asEuint64(0);
        totalWeightAggregated = FHE.asEuint64(0);
        participantCount = FHE.asEuint64(0);
        
        FHE.allowThis(totalAgeAggregated);
        FHE.allowThis(totalWeightAggregated);
        FHE.allowThis(participantCount);
    }

    function submitAnonymizedData(externalEuint64 ageStr, externalEuint64 weightStr, bytes calldata proofA, bytes calldata proofW) public {
        euint64 age = FHE.fromExternal(ageStr, proofA);
        euint64 ageWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 ageExposure = FHE.sub(ageWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 weight = FHE.fromExternal(weightStr, proofW);
        ebool notParticipated = FHE.not(hasParticipated[msg.sender]);
        
        euint64 ageToAdd = FHE.select(notParticipated, age, FHE.asEuint64(0));
        euint64 weightToAdd = FHE.select(notParticipated, weight, FHE.asEuint64(0));
        euint64 countToAdd = FHE.select(notParticipated, FHE.asEuint64(1), FHE.asEuint64(0));

        totalAgeAggregated = FHE.add(totalAgeAggregated, ageToAdd);
        totalWeightAggregated = FHE.add(totalWeightAggregated, weightToAdd);
        participantCount = FHE.add(participantCount, countToAdd);
        
        hasParticipated[msg.sender] = FHE.select(notParticipated, FHE.asEbool(true), hasParticipated[msg.sender]);

        FHE.allowThis(totalAgeAggregated);
        FHE.allowThis(totalWeightAggregated);
        FHE.allowThis(participantCount);
        FHE.allowThis(hasParticipated[msg.sender]);
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