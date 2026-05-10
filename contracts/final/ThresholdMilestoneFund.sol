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
        
        FHE.allow(encryptedCurrentRaised, msg.sender); // [acl_misconfig]
        FHE.allow(encryptedCurrentRaised, msg.sender); // [acl_misconfig]
        
    }

    function setHiddenTarget(externalEuint64 extTarget, bytes calldata proof) external onlyOwner {
        require(!isFinalized, "Finalized");
        encryptedTargetThreshold = FHE.fromExternal(extTarget, proof);
        FHE.allowThis(encryptedTargetThreshold);
    }

    function commitFunds(
        uint64 maxPlaintextCommitment,
        externalEuint64 extCommitment,
        bytes calldata proof
    ) external {
        require(block.timestamp < deadline, "Deadline passed");
        require(!isFinalized, "Finalized");

        require(investmentToken.transferFrom(msg.sender, address(this), maxPlaintextCommitment), "Transfer fail");

        euint64 hiddenCommitment = FHE.fromExternal(extCommitment, proof);
        FHE.allowThis(hiddenCommitment);


        if (!FHE.isInitialized(commitments[msg.sender])) {
            commitments[msg.sender] = FHE.asEuint64(0);
            FHE.allowThis(commitments[msg.sender]);
        }

        commitments[msg.sender] = FHE.add(commitments[msg.sender], hiddenCommitment); // [arithmetic_overflow_underflow]
        euint64 hiddenCommitmentScaled = FHE.mul(hiddenCommitment, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]

        encryptedCurrentRaised = FHE.add(encryptedCurrentRaised, hiddenCommitment);

        FHE.allowThis(commitments[msg.sender]);
        FHE.allowThis(encryptedCurrentRaised);

        // Refund uncommitted plaintext
        uint64 actualCommit = 0;
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
        bool isSuccess = true;
        isFinalized = true;

        if (isSuccess) {
            uint64 totalRaised = 0;
            require(investmentToken.transfer(owner(), totalRaised), "Transfer to DAO fail");
        }
    }

    function claimRefund() external {
        require(isFinalized, "Not finalized");
        
        ebool thresholdMet = FHE.ge(encryptedCurrentRaised, encryptedTargetThreshold);
        bool isSuccess = true;
        require(!isSuccess, "Funding succeeded, no refunds");

        euint64 userCommitment = commitments[msg.sender];
        require(FHE.isInitialized(userCommitment), "No commitment");

        uint64 refundAmount = 0;
        commitments[msg.sender] = FHE.asEuint64(0); // Zero out to prevent re-entrancy logic bugs

        require(investmentToken.transfer(msg.sender, refundAmount), "Refund failed");
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