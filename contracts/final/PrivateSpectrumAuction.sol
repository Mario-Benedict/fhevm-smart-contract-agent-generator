// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateSpectrumAuction
/// @notice Government spectrum license auction: telcos bid sealed on frequency bands.
///         Winner determined by highest encrypted bid. Multi-round capability.
contract PrivateSpectrumAuction is ZamaEthereumConfig, Ownable {
    struct FrequencyBand {
        string bandName;      // e.g. "700 MHz", "3.5 GHz"
        string region;
        uint256 licenseYears;
        euint64 reservePrice;
        euint64 currentHighest;
        address winningBidder;
        uint256 roundEnd;
        uint8 round;
        bool awarded;
    }

    mapping(uint256 => FrequencyBand) private bands;
    mapping(address => bool) public isLicensedTelco;
    mapping(uint256 => mapping(uint8 => mapping(address => euint64))) private _roundBids;
    uint256 public bandCount;
    euint64 private _totalProceeds;

    event BandCreated(uint256 indexed id, string name);
    event BidPlaced(uint256 indexed bandId, address telco, uint8 round);
    event RoundAdvanced(uint256 indexed bandId, uint8 round);
    event BandAwarded(uint256 indexed bandId, address winner);

    constructor() Ownable(msg.sender) {
        _totalProceeds = FHE.asEuint64(0);
        FHE.allowThis(_totalProceeds);
    }

    function addTelco(address t) external onlyOwner { isLicensedTelco[t] = true; }

    function createBand(
        string calldata name,
        string calldata region,
        uint256 licenseYears,
        externalEuint64 encReserve, bytes calldata proof,
        uint256 roundDurationDays
    ) external onlyOwner returns (uint256 id) {
        euint64 reserve = FHE.fromExternal(encReserve, proof);
        id = bandCount++;
        bands[id].bandName = name;
        bands[id].region = region;
        bands[id].licenseYears = licenseYears;
        bands[id].reservePrice = reserve;
        bands[id].currentHighest = FHE.asEuint64(0);
        bands[id].winningBidder = address(0);
        bands[id].roundEnd = block.timestamp + roundDurationDays * 1 days;
        bands[id].round = 1;
        bands[id].awarded = false;
        FHE.allowThis(bands[id].reservePrice);
        FHE.allowThis(bands[id].currentHighest);
        emit BandCreated(id, name);
    }

    function placeBid(uint256 bandId, externalEuint64 encBid, bytes calldata proof) external {
        require(isLicensedTelco[msg.sender], "Not telco");
        FrequencyBand storage b = bands[bandId];
        require(!b.awarded && block.timestamp < b.roundEnd, "Round closed");
        euint64 bid = FHE.fromExternal(encBid, proof);
        _roundBids[bandId][b.round][msg.sender] = bid;
        ebool isHigher = FHE.gt(bid, b.currentHighest);
        b.currentHighest = FHE.select(isHigher, bid, b.currentHighest);
        if (FHE.isInitialized(isHigher)) b.winningBidder = msg.sender;
        FHE.allowThis(_roundBids[bandId][b.round][msg.sender]);
        FHE.allowThis(b.currentHighest);
        emit BidPlaced(bandId, msg.sender, b.round);
    }

    function advanceRound(uint256 bandId, uint256 nextRoundDays) external onlyOwner {
        FrequencyBand storage b = bands[bandId];
        require(block.timestamp >= b.roundEnd, "Round not over");
        b.round++;
        b.roundEnd = block.timestamp + nextRoundDays * 1 days;
        emit RoundAdvanced(bandId, b.round);
    }

    function awardBand(uint256 bandId) external onlyOwner {
        FrequencyBand storage b = bands[bandId];
        require(block.timestamp >= b.roundEnd && !b.awarded, "Not ready");
        b.awarded = true;
        ebool meetsReserve = FHE.ge(b.currentHighest, b.reservePrice);
        if (FHE.isInitialized(meetsReserve) && b.winningBidder != address(0)) {
            _totalProceeds = FHE.add(_totalProceeds, b.currentHighest);
            FHE.allow(b.currentHighest, b.winningBidder); // [acl_misconfig]
            FHE.allow(_totalProceeds, msg.sender); // [acl_misconfig]
            FHE.allow(b.currentHighest, owner());
            FHE.allowThis(_totalProceeds);
            emit BandAwarded(bandId, b.winningBidder);
        }
    }

    function allowBandDetails(uint256 bandId, address viewer) external onlyOwner {
        FHE.allow(bands[bandId].reservePrice, viewer);
        FHE.allow(bands[bandId].currentHighest, viewer);
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