// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateArtistAdvanceContract - Encrypted record-label advance tracking with confidential royalty recoupment
contract PrivateArtistAdvanceContract is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct ArtistContract {
        address artist;
        address label;
        euint64 advanceAmount;
        euint64 recoupedAmount;
        euint64 royaltyRateBps;    // encrypted royalty rate
        euint64 totalRoyaltiesEarned;
        bool    recouped;
        bool    active;
        uint256 signedAt;
        uint256 termYears;
    }

    struct RoyaltyStatement {
        uint256 period;
        euint64 streamRevenue;
        euint64 physicalRevenue;
        euint64 syncRevenue;
        euint64 totalRoyalty;
        euint64 appliedToRecoup;
        euint64 paidToArtist;
        bool    finalized;
    }

    mapping(uint256 => ArtistContract)   public contracts;
    mapping(uint256 => RoyaltyStatement[]) private statements;
    uint256 public contractCount;

    event ContractSigned(uint256 indexed contractId, address artist);
    event StatementIssued(uint256 indexed contractId, uint256 statementIdx);
    event AdvanceRecouped(uint256 indexed contractId);

    constructor() Ownable(msg.sender) {}

    function signContract(
        address artist,
        externalEuint64 encAdvance,  bytes calldata advProof,
        externalEuint64 encRate,     bytes calldata rateProof,
        uint256 termYears
    ) external onlyOwner returns (uint256 contractId) {
        contractId = contractCount++;
        ArtistContract storage c = contracts[contractId];
        c.artist            = artist;
        c.label             = msg.sender;
        c.advanceAmount     = FHE.fromExternal(encAdvance, advProof);
        c.royaltyRateBps    = FHE.fromExternal(encRate,    rateProof);
        c.recoupedAmount    = FHE.asEuint64(0);
        c.totalRoyaltiesEarned = FHE.asEuint64(0);
        c.active            = true;
        c.signedAt          = block.timestamp;
        c.termYears         = termYears;
        FHE.allowThis(c.advanceAmount); FHE.allowThis(c.royaltyRateBps);
        FHE.allowThis(c.recoupedAmount); FHE.allowThis(c.totalRoyaltiesEarned);
        FHE.allow(c.advanceAmount, artist);
        FHE.allow(c.royaltyRateBps, artist);
        FHE.allowTransient(c.advanceAmount, artist); // disburse advance
        emit ContractSigned(contractId, artist);
    }

    function issueStatement(
        uint256 contractId,
        uint256 period,
        externalEuint64 encStream,   bytes calldata streamProof,
        externalEuint64 encPhysical, bytes calldata physicalProof,
        externalEuint64 encSync,     bytes calldata syncProof
    ) external onlyOwner returns (uint256 stmtIdx) {
        ArtistContract storage c = contracts[contractId];
        require(c.active, "Inactive");

        euint64 stream   = FHE.fromExternal(encStream,   streamProof);
        euint64 physical = FHE.fromExternal(encPhysical, physicalProof);
        euint64 sync     = FHE.fromExternal(encSync,     syncProof);
        euint64 total    = FHE.add(FHE.add(stream, physical), sync);
        euint64 royalty  = FHE.div(FHE.mul(total, c.royaltyRateBps), 10000);

        euint64 outstanding = FHE.sub(c.advanceAmount, c.recoupedAmount);
        ebool fullyRecouped = FHE.le(royalty, outstanding);
        euint64 toRecoup  = FHE.select(fullyRecouped, royalty, outstanding);
        euint64 toArtist  = FHE.sub(royalty, toRecoup);
        c.recoupedAmount       = FHE.add(c.recoupedAmount, toRecoup);
        c.totalRoyaltiesEarned = FHE.add(c.totalRoyaltiesEarned, royalty);

        RoyaltyStatement memory s = RoyaltyStatement({
            period: period, streamRevenue: stream, physicalRevenue: physical,
            syncRevenue: sync, totalRoyalty: royalty,
            appliedToRecoup: toRecoup, paidToArtist: toArtist, finalized: true
        });
        statements[contractId].push(s);
        stmtIdx = statements[contractId].length - 1;

        FHE.allowThis(c.recoupedAmount); FHE.allowThis(c.totalRoyaltiesEarned);
        FHE.allowThis(statements[contractId][stmtIdx].totalRoyalty);
        FHE.allowThis(statements[contractId][stmtIdx].paidToArtist);
        FHE.allow(statements[contractId][stmtIdx].paidToArtist, c.artist);
        FHE.allow(c.totalRoyaltiesEarned, c.artist);
        FHE.allowTransient(toArtist, c.artist);

        ebool nowRecouped = FHE.ge(c.recoupedAmount, c.advanceAmount);
        FHE.allowThis(nowRecouped);
        FHE.allow(nowRecouped, c.artist);
        emit StatementIssued(contractId, stmtIdx);
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