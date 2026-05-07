// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedAnonymousFreelance is ZamaEthereumConfig, Ownable {
    struct Job {
        euint64 budget;
        euint8 status; // 0=Open, 1=InProgress, 2=Completed
        address freelancer;
    }

    mapping(uint256 => Job) public jobs;
    mapping(address => euint64) public balances;
    uint256 public nextJobId;

    constructor() Ownable(msg.sender) {}

    function postJob(externalEuint64 budgetStr, bytes calldata proof) public payable {
        // Budget is fully encrypted
        jobs[nextJobId] = Job({
            budget: FHE.fromExternal(budgetStr, proof),
            status: FHE.asEuint8(0),
            freelancer: address(0)
        });
        FHE.allowThis(jobs[nextJobId].budget);
        FHE.allowThis(jobs[nextJobId].status);
        nextJobId++;
    }

    function acceptJob(uint256 jobId) public {
        ebool isOpen = FHE.eq(jobs[jobId].status, FHE.asEuint8(0));
        jobs[jobId].status = FHE.select(isOpen, FHE.asEuint8(1), jobs[jobId].status);
        
        jobs[jobId].freelancer = msg.sender;
        FHE.allowThis(jobs[jobId].status);
    }

    function completeJob(uint256 jobId) public onlyOwner {
        ebool inProgress = FHE.eq(jobs[jobId].status, FHE.asEuint8(1));
        
        euint64 payout = FHE.select(inProgress, jobs[jobId].budget, FHE.asEuint64(0));
        jobs[jobId].status = FHE.select(inProgress, FHE.asEuint8(2), jobs[jobId].status);
        
        address f = jobs[jobId].freelancer;
        balances[f] = FHE.add(balances[f], payout);
        
        FHE.allowThis(jobs[jobId].status);
        FHE.allowThis(balances[f]);
    }
}
