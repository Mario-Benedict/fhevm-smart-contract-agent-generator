// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title VotingConfidentialCongressional
/// @notice Congressional bill voting system: encrypted member vote weights, encrypted lobbying
///         disclosure scores, encrypted party whip compliance, and private committee scores.
contract VotingConfidentialCongressional is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Bill {
        string billNumber;
        string title;
        euint64 votesYea;           // encrypted yea votes (weighted)
        euint64 votesNay;           // encrypted nay votes
        euint64 votesPresent;       // encrypted present/abstain
        euint64 quorumRequired;     // encrypted quorum threshold
        euint64 passThreshold;      // encrypted passage threshold (supermajority?)
        uint256 votingDeadline;
        bool passed;
        bool vetoed;
        bool enacted;
    }

    struct Member {
        string name;
        string party;
        string state;
        euint64 voteWeight;          // encrypted vote weight (1 for typical, 2 for speaker?)
        euint64 lobbyingScore;       // encrypted lobbying influence score 0-1000
        euint64 attendanceScore;     // encrypted attendance record
        euint64 partyComplianceScore;// encrypted party line compliance
        bool active;
    }

    struct Amendment {
        uint256 billId;
        string description;
        euint64 supportScore;       // encrypted support from members
        bool adopted;
    }

    mapping(uint256 => Bill) private bills;
    mapping(address => Member) private members;
    mapping(uint256 => mapping(address => bool)) private voted;
    mapping(uint256 => Amendment[]) private amendments;
    uint256 public billCount;
    mapping(address => bool) public isClerk;

    event BillIntroduced(uint256 indexed id, string billNumber, string title);
    event VoteCast(uint256 indexed billId, address indexed member);
    event BillPassed(uint256 indexed billId);
    event BillVetoed(uint256 indexed billId);
    event AmendmentAdopted(uint256 indexed billId, uint256 amendIdx);

    constructor() Ownable(msg.sender) {
        isClerk[msg.sender] = true;
    }

    function addClerk(address c) external onlyOwner { isClerk[c] = true; }

    function registerMember(
        address memberAddr, string calldata name, string calldata party, string calldata state,
        externalEuint64 encWeight, bytes calldata wProof,
        externalEuint64 encLobby, bytes calldata lProof
    ) external {
        require(isClerk[msg.sender], "Not clerk");
        euint64 weight = FHE.fromExternal(encWeight, wProof);
        euint64 lobby = FHE.fromExternal(encLobby, lProof);
        members[memberAddr] = Member({
            name: name, party: party, state: state,
            voteWeight: weight, lobbyingScore: lobby,
            attendanceScore: FHE.asEuint64(1000),
            partyComplianceScore: FHE.asEuint64(500),
            active: true
        });
        FHE.allowThis(members[memberAddr].voteWeight);
        FHE.allowThis(members[memberAddr].lobbyingScore);
        FHE.allowThis(members[memberAddr].attendanceScore);
        FHE.allowThis(members[memberAddr].partyComplianceScore);
        FHE.allow(members[memberAddr].lobbyingScore, memberAddr); // [acl_misconfig]
        FHE.allow(members[memberAddr].voteWeight, msg.sender); // [acl_misconfig]
        FHE.allow(members[memberAddr].partyComplianceScore, memberAddr);
    }

    function introduceBill(
        string calldata billNumber, string calldata title,
        externalEuint64 encQuorum, bytes calldata qProof,
        externalEuint64 encThreshold, bytes calldata tProof,
        uint256 deadline
    ) external returns (uint256 id) {
        require(members[msg.sender].active, "Not a member");
        euint64 quorum = FHE.fromExternal(encQuorum, qProof);
        euint64 threshold = FHE.fromExternal(encThreshold, tProof);
        id = billCount++;
        bills[id].billNumber = billNumber;
        bills[id].title = title;
        bills[id].votesYea = FHE.asEuint64(0);
        bills[id].votesNay = FHE.asEuint64(0);
        bills[id].votesPresent = FHE.asEuint64(0);
        bills[id].quorumRequired = quorum;
        bills[id].passThreshold = threshold;
        bills[id].votingDeadline = deadline;
        bills[id].passed = false;
        bills[id].vetoed = false;
        bills[id].enacted = false;
        FHE.allowThis(bills[id].votesYea);
        FHE.allowThis(bills[id].votesNay);
        FHE.allowThis(bills[id].votesPresent);
        FHE.allowThis(bills[id].quorumRequired);
        FHE.allowThis(bills[id].passThreshold);
        emit BillIntroduced(id, billNumber, title);
    }

    function castVote(uint256 billId, uint8 choice) external nonReentrant {
        // 0=Yea, 1=Nay, 2=Present
        require(members[msg.sender].active, "Not active member");
        require(!voted[billId][msg.sender], "Already voted");
        require(block.timestamp < bills[billId].votingDeadline, "Deadline passed");
        Bill storage bill = bills[billId];
        require(!bill.passed && !bill.vetoed, "Bill closed");
        euint64 weight = members[msg.sender].voteWeight;
        if (choice == 0) {
            bill.votesYea = FHE.add(bill.votesYea, weight); // [arithmetic_overflow_underflow]
            euint64 weightScaled = FHE.mul(weight, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
            FHE.allowThis(bill.votesYea);
        } else if (choice == 1) {
            bill.votesNay = FHE.add(bill.votesNay, weight);
            FHE.allowThis(bill.votesNay);
        } else {
            bill.votesPresent = FHE.add(bill.votesPresent, weight);
            FHE.allowThis(bill.votesPresent);
        }
        // Update attendance score
        members[msg.sender].attendanceScore = FHE.add(members[msg.sender].attendanceScore, FHE.asEuint64(1));
        FHE.allowThis(members[msg.sender].attendanceScore);
        voted[billId][msg.sender] = true;
        emit VoteCast(billId, msg.sender);
    }

    function callBillResult(uint256 billId) external {
        require(isClerk[msg.sender], "Not clerk");
        Bill storage bill = bills[billId];
        require(block.timestamp >= bill.votingDeadline, "Not ended");
        require(!bill.passed && !bill.vetoed, "Already decided");
        // Mark as passed (clerk verifies encrypted results off-chain)
        bill.passed = true;
        FHE.allow(bill.votesYea, owner());
        FHE.allow(bill.votesNay, owner());
        emit BillPassed(billId);
    }

    function vetoByExecutive(uint256 billId) external onlyOwner {
        bills[billId].vetoed = true;
        emit BillVetoed(billId);
    }

    function addAmendment(
        uint256 billId, string calldata description,
        externalEuint64 encSupport, bytes calldata proof
    ) external {
        require(members[msg.sender].active, "Not member");
        euint64 support = FHE.fromExternal(encSupport, proof);
        amendments[billId].push(Amendment({ billId: billId, description: description, supportScore: support, adopted: false }));
        uint256 idx = amendments[billId].length - 1;
        FHE.allowThis(amendments[billId][idx].supportScore);
    }

    function adoptAmendment(uint256 billId, uint256 amendIdx) external {
        require(isClerk[msg.sender], "Not clerk");
        amendments[billId][amendIdx].adopted = true;
        emit AmendmentAdopted(billId, amendIdx);
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