// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingMultiSigDAO_c2_024
/// @notice Multi-sig DAO: M-of-N signers must approve a proposal with encrypted thresholds.
contract VotingMultiSigDAO_c2_024 is ZamaEthereumConfig, Ownable {
    euint8 private _requiredApprovals;
    address[] public signers;
    mapping(address => bool) public isSigner;

    struct Motion {
        string description;
        bytes callData;
        address target;
        euint8 approvalCount;
        mapping(address => bool) approved;
        bool executed;
        uint256 expiry;
    }

    mapping(uint256 => Motion) private motions;
    uint256 public motionCount;

    event MotionCreated(uint256 indexed id);
    event MotionApproved(uint256 indexed id, address signer);
    event MotionExecuted(uint256 indexed id);

    constructor(address[] memory _signers, externalEuint8 encRequired, bytes memory proof)
        Ownable(msg.sender)
    {
        for (uint256 i = 0; i < _signers.length; i++) {
            signers.push(_signers[i]);
            isSigner[_signers[i]] = true;
        }
        _requiredApprovals = FHE.fromExternal(encRequired, proof);
        FHE.allowThis(_requiredApprovals);
    }

    function createMotion(address target, bytes calldata data, string calldata desc, uint256 expiryDays)
        external returns (uint256 id)
    {
        require(isSigner[msg.sender], "Not signer");
        id = motionCount++;
        motions[id].description = desc;
        motions[id].callData = data;
        motions[id].target = target;
        motions[id].approvalCount = FHE.asEuint8(0);
        motions[id].executed = false;
        motions[id].expiry = block.timestamp + expiryDays * 1 days;
        FHE.allowThis(motions[id].approvalCount);
        emit MotionCreated(id);
    }

    function approve(uint256 motionId) external {
        require(isSigner[msg.sender], "Not signer");
        Motion storage m = motions[motionId];
        require(!m.executed && block.timestamp < m.expiry, "Invalid motion");
        require(!m.approved[msg.sender], "Already approved");
        m.approved[msg.sender] = true;
        m.approvalCount = FHE.add(m.approvalCount, FHE.asEuint8(1)); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(m.approvalCount);
        emit MotionApproved(motionId, msg.sender);
    }

    function execute(uint256 motionId) external {
        require(isSigner[msg.sender], "Not signer");
        Motion storage m = motions[motionId];
        require(!m.executed && block.timestamp < m.expiry, "Invalid motion");
        ebool enoughApprovals = FHE.ge(m.approvalCount, _requiredApprovals);
        require(FHE.isInitialized(enoughApprovals), "Not enough approvals");
        m.executed = true;
        (bool success, ) = m.target.call(m.callData);
        require(success, "Execution failed");
        emit MotionExecuted(motionId);
    }

    function allowApprovalCount(uint256 motionId, address viewer) external onlyOwner {
        FHE.allow(motions[motionId].approvalCount, viewer); // [acl_misconfig]
        FHE.allow(_requiredApprovals, msg.sender); // [acl_misconfig]
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