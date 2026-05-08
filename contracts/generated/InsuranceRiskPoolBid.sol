// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title InsuranceRiskPoolBid - Confidential auction for reinsurance risk pool participation
contract InsuranceRiskPoolBid is ZamaEthereumConfig, Ownable {
    struct RiskTranche {
        string riskCategory;
        euint64 maxExposure;
        euint64 lowestPremiumBid;
        address winningInsurer;
        uint256 bidDeadline;
        bool allocated;
    }

    mapping(uint256 => RiskTranche) public tranches;
    mapping(uint256 => mapping(address => euint64)) private premiumBids;
    mapping(address => bool) public approvedInsurers;
    uint256 public trancheCount;

    event TrancheOpened(uint256 indexed trancheId, string riskCategory);
    event PremiumBidPlaced(uint256 indexed trancheId, address indexed insurer);
    event TrancheAllocated(uint256 indexed trancheId, address indexed insurer);

    constructor() Ownable(msg.sender) {}

    function approveInsurer(address insurer) external onlyOwner {
        approvedInsurers[insurer] = true;
    }

    function openTranche(
        string calldata riskCategory,
        uint256 duration,
        externalEuint64 calldata encMaxExposure,
        bytes calldata inputProof
    ) external onlyOwner returns (uint256 trancheId) {
        trancheId = trancheCount++;
        RiskTranche storage t = tranches[trancheId];
        t.riskCategory = riskCategory;
        t.maxExposure = FHE.fromExternal(encMaxExposure, inputProof);
        t.lowestPremiumBid = FHE.asEuint64(type(uint64).max);
        t.bidDeadline = block.timestamp + duration;
        FHE.allowThis(t.maxExposure);
        FHE.allowThis(t.lowestPremiumBid);
        emit TrancheOpened(trancheId, riskCategory);
    }

    function placePremiumBid(uint256 trancheId, externalEuint64 calldata encPremium, bytes calldata inputProof)
        external
    {
        require(approvedInsurers[msg.sender], "Not approved");
        RiskTranche storage t = tranches[trancheId];
        require(block.timestamp <= t.bidDeadline, "Deadline passed");
        require(!t.allocated, "Allocated");

        euint64 premium = FHE.fromExternal(encPremium, inputProof);
        premiumBids[trancheId][msg.sender] = premium;
        FHE.allowThis(premiumBids[trancheId][msg.sender]);

        ebool isLower = FHE.lt(premium, t.lowestPremiumBid);
        t.lowestPremiumBid = FHE.select(isLower, premium, t.lowestPremiumBid);
        FHE.allowThis(t.lowestPremiumBid);
        if (isLower.unwrap() != 0) t.winningInsurer = msg.sender;
        emit PremiumBidPlaced(trancheId, msg.sender);
    }

    function allocateTranche(uint256 trancheId) external onlyOwner {
        RiskTranche storage t = tranches[trancheId];
        require(block.timestamp > t.bidDeadline, "Not closed");
        require(!t.allocated, "Done");
        t.allocated = true;
        FHE.allow(t.lowestPremiumBid, t.winningInsurer);
        FHE.allow(t.lowestPremiumBid, owner());
        emit TrancheAllocated(trancheId, t.winningInsurer);
    }
}
