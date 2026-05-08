// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ThresholdMilestoneFund is ZamaEthereumConfig, Ownable {
    IERC20 public immutable investmentToken;
    
    euint64 public encryptedTargetThreshold;
    euint64 public encryptedCurrentRaised;
    
    uint256 public deadline;
    bool public isFinalized;

    mapping(address => euint64) private commitments;

    constructor(address _token, uint256 _duration) Ownable(msg.sender) {
        investmentToken = IERC20(_token);
        deadline = block.timestamp + _duration;
        encryptedCurrentRaised = FHE.asEuint64(0);
        
        FHE.allowThis(encryptedCurrentRaised);
    }

    function setHiddenTarget(externalEuint64 memory extTarget, bytes calldata proof) external onlyOwner {
        require(!isFinalized, "Finalized");
        encryptedTargetThreshold = FHE.fromExternal(extTarget, proof);
        FHE.allowThis(encryptedTargetThreshold);
    }

    function commitFunds(
        uint64 maxPlaintextCommitment,
        externalEuint64 memory extCommitment,
        bytes calldata proof
    ) external {
        require(block.timestamp < deadline, "Deadline passed");
        require(!isFinalized, "Finalized");

        require(investmentToken.transferFrom(msg.sender, address(this), maxPlaintextCommitment), "Transfer fail");

        euint64 hiddenCommitment = FHE.fromExternal(extCommitment, proof);
        FHE.allowThis(hiddenCommitment);

        FHE.req(FHE.le(hiddenCommitment, FHE.asEuint64(maxPlaintextCommitment)));

        if (!FHE.isInitialized(commitments[msg.sender])) {
            commitments[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(commitments[msg.sender]);
        }

        commitments[msg.sender] = FHE.add(commitments[msg.sender], hiddenCommitment);
        encryptedCurrentRaised = FHE.add(encryptedCurrentRaised, hiddenCommitment);

        FHE.allowThis(commitments[msg.sender]);
        FHE.allowThis(encryptedCurrentRaised);

        // Refund uncommitted plaintext
        uint64 actualCommit = FHE.decrypt(hiddenCommitment);
        if (maxPlaintextCommitment > actualCommit) {
            require(investmentToken.transfer(msg.sender, maxPlaintextCommitment - actualCommit), "Refund fail");
        }
    }

    function finalizeFunding() external {
        require(block.timestamp >= deadline, "Not ended");
        require(!isFinalized, "Already finalized");

        ebool thresholdMet = FHE.ge(encryptedCurrentRaised, encryptedTargetThreshold);
        
        // If threshold met, funds go to owner. If not, users can claim refunds.
        // We evaluate this publicly at the end to settle the contract physically.
        bool isSuccess = FHE.decrypt(thresholdMet);
        isFinalized = true;

        if (isSuccess) {
            uint64 totalRaised = FHE.decrypt(encryptedCurrentRaised);
            require(investmentToken.transfer(owner(), totalRaised), "Transfer to DAO fail");
        }
    }

    function claimRefund() external {
        require(isFinalized, "Not finalized");
        
        ebool thresholdMet = FHE.ge(encryptedCurrentRaised, encryptedTargetThreshold);
        bool isSuccess = FHE.decrypt(thresholdMet);
        require(!isSuccess, "Funding succeeded, no refunds");

        euint64 userCommitment = commitments[msg.sender];
        require(FHE.isInitialized(userCommitment), "No commitment");

        uint64 refundAmount = FHE.decrypt(userCommitment);
        commitments[msg.sender] = FHE.asEuint64(0); // Zero out to prevent re-entrancy logic bugs

        require(investmentToken.transfer(msg.sender, refundAmount), "Refund failed");
    }
}