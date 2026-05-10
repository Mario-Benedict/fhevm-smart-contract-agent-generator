// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingCooperativeDividend
/// @notice Agricultural/worker cooperative dividend vote. Member share counts are encrypted.
///         Members vote on profit distribution ratio (retained vs. distributed).
///         Dividends are calculated privately based on encrypted shareholding.
contract VotingCooperativeDividend is ZamaEthereumConfig, Ownable {
    struct Member {
        euint32 shares;
        euint64 dividendBalance;
        bool registered;
        mapping(uint256 => bool) voted;
    }

    struct DividendRound {
        euint64 totalProfit;
        euint16 distributionRatioBps; // encrypted % to distribute
        euint32 approvalShares;
        euint32 rejectionShares;
        bool finalized;
        bool distributed;
        uint256 deadline;
    }

    mapping(address => Member) private members;
    address[] public memberList;
    mapping(uint256 => DividendRound) private rounds;
    uint256 public roundCount;
    euint32 private _totalShares;

    event MemberRegistered(address indexed m);
    event RoundCreated(uint256 indexed id);
    event VoteCast(uint256 indexed id, address member);
    event DividendsDistributed(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalShares = FHE.asEuint32(0);
        FHE.allowThis(_totalShares);
    }

    function registerMember(address m, externalEuint32 encShares, bytes calldata proof) external onlyOwner {
        euint32 shares = FHE.fromExternal(encShares, proof);
        members[m].shares = shares;
        members[m].dividendBalance = FHE.asEuint64(0);
        members[m].registered = true;
        _totalShares = FHE.add(_totalShares, shares); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        FHE.allowThis(members[m].shares);
        FHE.allow(members[m].shares, m); // [acl_misconfig]
        FHE.allow(_totalShares, msg.sender); // [acl_misconfig]
        FHE.allowThis(members[m].dividendBalance);
        FHE.allow(members[m].dividendBalance, m);
        FHE.allowThis(_totalShares);
        memberList.push(m);
        emit MemberRegistered(m);
    }

    function createRound(
        externalEuint64 encProfit, bytes calldata pProof,
        externalEuint16 encRatio, bytes calldata rProof,
        uint256 daysToVote
    ) external onlyOwner returns (uint256 id) {
        id = roundCount++;
        DividendRound storage r = rounds[id];
        r.totalProfit = FHE.fromExternal(encProfit, pProof);
        r.distributionRatioBps = FHE.fromExternal(encRatio, rProof);
        r.approvalShares = FHE.asEuint32(0);
        r.rejectionShares = FHE.asEuint32(0);
        r.deadline = block.timestamp + daysToVote * 1 days;
        FHE.allowThis(r.totalProfit);
        FHE.allowThis(r.distributionRatioBps);
        FHE.allowThis(r.approvalShares);
        FHE.allowThis(r.rejectionShares);
        emit RoundCreated(id);
    }

    function vote(uint256 roundId, bool approve) external {
        Member storage m = members[msg.sender];
        require(m.registered, "Not member");
        DividendRound storage r = rounds[roundId];
        require(!r.finalized && block.timestamp <= r.deadline, "Closed");
        require(!m.voted[roundId], "Already voted");
        m.voted[roundId] = true;
        if (approve) {
            r.approvalShares = FHE.add(r.approvalShares, m.shares);
            FHE.allowThis(r.approvalShares);
        } else {
            r.rejectionShares = FHE.add(r.rejectionShares, m.shares);
            FHE.allowThis(r.rejectionShares);
        }
        emit VoteCast(roundId, msg.sender);
    }

    function finalizeAndDistribute(uint256 roundId) external onlyOwner {
        DividendRound storage r = rounds[roundId];
        require(!r.finalized, "Already finalized");
        r.finalized = true;
        ebool approved = FHE.gt(r.approvalShares, r.rejectionShares);
        if (!FHE.isInitialized(approved)) return;
        r.distributed = true;
        euint64 toDistribute = FHE.div(FHE.mul(r.totalProfit, 0), 10000);
        // For each member, calculate proportional dividend
        for (uint256 i = 0; i < memberList.length; i++) {
            address mAddr = memberList[i];
            Member storage mem = members[mAddr];
            euint64 share = FHE.div(FHE.mul(r.totalProfit, 1), uint64(memberList.length));
            mem.dividendBalance = FHE.add(mem.dividendBalance, share);
            FHE.allowThis(mem.dividendBalance);
            FHE.allow(mem.dividendBalance, mAddr);
        }
        emit DividendsDistributed(roundId);
    }

    function claimDividend(externalEuint64 encAmount, bytes calldata proof) external {
        Member storage m = members[msg.sender];
        require(m.registered, "Not member");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, m.dividendBalance);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        m.dividendBalance = FHE.sub(m.dividendBalance, actual);
        FHE.allowThis(m.dividendBalance);
        FHE.allow(m.dividendBalance, msg.sender);
        FHE.allow(actual, msg.sender);
    }

    function allowMemberData(address viewer) external {
        FHE.allow(members[msg.sender].shares, viewer);
        FHE.allow(members[msg.sender].dividendBalance, viewer);
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