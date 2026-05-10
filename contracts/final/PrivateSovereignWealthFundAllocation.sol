// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateSovereignWealthFundAllocation
/// @notice SWF allocates encrypted capital across asset classes with board governance.
contract PrivateSovereignWealthFundAllocation is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum AssetClass { Equities, Bonds, RealAssets, PrivateEquity, Commodities, Cash }
    enum ProposalStatus { Active, Passed, Rejected, Executed }

    struct AllocationBucket {
        euint64 allocatedCapitalUSD;
        euint64 targetReturnBps;
        euint64 actualReturnBps;
        euint32 maxWeightBps;
        bool active;
    }

    struct AllocationProposal {
        AssetClass targetClass;
        euint64 proposedAmountUSD;
        euint32 yesVotesWeighted;
        euint32 noVotesWeighted;
        ProposalStatus status;
        uint256 deadline;
        address proposer;
    }

    struct BoardMember {
        euint32 votingWeightBps;
        bool active;
    }

    mapping(uint8 => AllocationBucket) private buckets;
    mapping(uint256 => AllocationProposal) private proposals;
    mapping(address => BoardMember) private boardMembers;
    mapping(uint256 => mapping(address => bool)) private hasVoted;

    uint256 public proposalCount;
    euint64 private _totalAUM;
    euint64 private _totalAllocated;

    event ProposalCreated(uint256 indexed id, AssetClass target);
    event VoteCast(uint256 indexed id, address voter);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyBoard() {
        require(boardMembers[msg.sender].active, "Not board member");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalAUM = FHE.asEuint64(0);
        _totalAllocated = FHE.asEuint64(0);
        FHE.allowThis(_totalAUM);
        FHE.allowThis(_totalAllocated);
        boardMembers[msg.sender] = BoardMember({ votingWeightBps: FHE.asEuint32(10000), active: true });
        FHE.allowThis(boardMembers[msg.sender].votingWeightBps);
    }

    function addBoardMember(address member, externalEuint32 encWeight, bytes calldata proof) external onlyOwner {
        euint32 weight = FHE.fromExternal(encWeight, proof);
        boardMembers[member] = BoardMember({ votingWeightBps: weight, active: true });
        FHE.allowThis(boardMembers[member].votingWeightBps);
        FHE.allow(boardMembers[member].votingWeightBps, member); // [acl_misconfig]
        FHE.allow(_totalAUM, msg.sender); // [acl_misconfig]
        FHE.allow(_totalAllocated, msg.sender); // [acl_misconfig]
    }

    function depositAUM(externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _totalAUM = FHE.add(_totalAUM, amount);
        FHE.allowThis(_totalAUM);
    }

    function proposeAllocation(
        AssetClass target, externalEuint64 encAmount, bytes calldata proof, uint256 votingDays
    ) external onlyBoard whenNotPaused returns (uint256 id) {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        id = proposalCount++;
        proposals[id] = AllocationProposal({
            targetClass: target, proposedAmountUSD: amount,
            yesVotesWeighted: FHE.asEuint32(0), noVotesWeighted: FHE.asEuint32(0),
            status: ProposalStatus.Active,
            deadline: block.timestamp + votingDays * 1 days,
            proposer: msg.sender
        });
        FHE.allowThis(proposals[id].proposedAmountUSD);
        FHE.allowThis(proposals[id].yesVotesWeighted);
        FHE.allowThis(proposals[id].noVotesWeighted);
        emit ProposalCreated(id, target);
    }

    function voteProposal(uint256 id, bool support) external onlyBoard {
        require(!hasVoted[id][msg.sender], "Already voted");
        require(proposals[id].status == ProposalStatus.Active, "Not active");
        require(block.timestamp < proposals[id].deadline, "Deadline passed");
        hasVoted[id][msg.sender] = true;
        AllocationProposal storage p = proposals[id];
        if (support) {
            p.yesVotesWeighted = FHE.add(p.yesVotesWeighted, boardMembers[msg.sender].votingWeightBps);
            FHE.allowThis(p.yesVotesWeighted);
        } else {
            p.noVotesWeighted = FHE.add(p.noVotesWeighted, boardMembers[msg.sender].votingWeightBps);
            FHE.allowThis(p.noVotesWeighted);
        }
        emit VoteCast(id, msg.sender);
    }

    function finalizeProposal(uint256 id) external onlyBoard {
        AllocationProposal storage p = proposals[id];
        require(p.status == ProposalStatus.Active && block.timestamp >= p.deadline, "Not ended");
        ebool passed = FHE.gt(p.yesVotesWeighted, p.noVotesWeighted);
        p.status = FHE.isInitialized(passed) ? ProposalStatus.Passed : ProposalStatus.Rejected;
    }

    function executeProposal(uint256 id) external onlyOwner nonReentrant {
        AllocationProposal storage p = proposals[id];
        require(p.status == ProposalStatus.Passed, "Not passed");
        uint8 ac = uint8(p.targetClass);
        buckets[ac].allocatedCapitalUSD = FHE.add(buckets[ac].allocatedCapitalUSD, p.proposedAmountUSD);
        _totalAllocated = FHE.add(_totalAllocated, p.proposedAmountUSD);
        p.status = ProposalStatus.Executed;
        FHE.allowThis(buckets[ac].allocatedCapitalUSD);
        FHE.allowThis(_totalAllocated);
        emit ProposalExecuted(id);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalAUM, viewer);
        FHE.allow(_totalAllocated, viewer);
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