// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedFranchiseRoyalty - Private franchise revenue reporting and royalty remittance
contract EncryptedFranchiseRoyalty is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Franchisee {
        string locationCode;
        euint8  royaltyRateBps; // rate in 0.01% increments
        euint64 totalRevenue;
        euint64 totalRoyaltiesPaid;
        euint64 outstandingRoyalties;
        bool    active;
        uint256 onboardedAt;
    }

    struct RevenueReport {
        uint256 periodStart;
        uint256 periodEnd;
        euint64 grossRevenue;
        euint64 royaltyDue;
        bool    settled;
    }

    mapping(address => Franchisee) public franchisees;
    mapping(address => RevenueReport[]) private reports;
    address[] public franchiseeList;
    euint64 private totalNetworkRoyalties;

    event FranchiseeOnboarded(address indexed franchisee, string location);
    event RevenueReported(address indexed franchisee, uint256 reportIndex);
    event RoyaltySettled(address indexed franchisee, uint256 reportIndex);
    event RoyaltyRateUpdated(address indexed franchisee);

    constructor() Ownable(msg.sender) {
        totalNetworkRoyalties = FHE.asEuint64(0);
        FHE.allowThis(totalNetworkRoyalties);
    }

    function onboardFranchisee(
        address franchisee,
        string calldata locationCode,
        externalEuint8 calldata encRate, bytes calldata rateProof
    ) external onlyOwner {
        require(!franchisees[franchisee].active, "Already active");
        Franchisee storage f = franchisees[franchisee];
        f.locationCode       = locationCode;
        f.royaltyRateBps     = FHE.fromExternal(encRate, rateProof);
        f.totalRevenue       = FHE.asEuint64(0);
        f.totalRoyaltiesPaid = FHE.asEuint64(0);
        f.outstandingRoyalties = FHE.asEuint64(0);
        f.active             = true;
        f.onboardedAt        = block.timestamp;
        FHE.allowThis(f.royaltyRateBps); FHE.allowThis(f.totalRevenue);
        FHE.allowThis(f.totalRoyaltiesPaid); FHE.allowThis(f.outstandingRoyalties);
        FHE.allow(f.royaltyRateBps, franchisee);
        FHE.allow(f.outstandingRoyalties, franchisee);
        franchiseeList.push(franchisee);
        emit FranchiseeOnboarded(franchisee, locationCode);
    }

    function reportRevenue(
        uint256 periodStart,
        uint256 periodEnd,
        externalEuint64 calldata encRevenue, bytes calldata inputProof
    ) external returns (uint256 reportIdx) {
        Franchisee storage f = franchisees[msg.sender];
        require(f.active, "Not active");
        euint64 revenue = FHE.fromExternal(encRevenue, inputProof);
        euint64 royalty = FHE.div(
            FHE.mul(revenue, FHE.asEuint64(f.royaltyRateBps.unwrap())),
            FHE.asEuint64(10000)
        );
        reports[msg.sender].push(RevenueReport({
            periodStart: periodStart, periodEnd: periodEnd,
            grossRevenue: revenue, royaltyDue: royalty, settled: false
        }));
        reportIdx = reports[msg.sender].length - 1;
        f.totalRevenue         = FHE.add(f.totalRevenue, revenue);
        f.outstandingRoyalties = FHE.add(f.outstandingRoyalties, royalty);
        FHE.allowThis(reports[msg.sender][reportIdx].grossRevenue);
        FHE.allowThis(reports[msg.sender][reportIdx].royaltyDue);
        FHE.allowThis(f.totalRevenue); FHE.allowThis(f.outstandingRoyalties);
        FHE.allow(reports[msg.sender][reportIdx].royaltyDue, owner());
        FHE.allow(f.outstandingRoyalties, msg.sender);
        emit RevenueReported(msg.sender, reportIdx);
    }

    function settleRoyalty(address franchisee, uint256 reportIdx) external onlyOwner nonReentrant {
        RevenueReport storage r = reports[franchisee][reportIdx];
        require(!r.settled, "Already settled");
        r.settled = true;
        Franchisee storage f = franchisees[franchisee];
        f.totalRoyaltiesPaid   = FHE.add(f.totalRoyaltiesPaid, r.royaltyDue);
        f.outstandingRoyalties = FHE.sub(f.outstandingRoyalties, r.royaltyDue);
        totalNetworkRoyalties  = FHE.add(totalNetworkRoyalties, r.royaltyDue);
        FHE.allowThis(f.totalRoyaltiesPaid); FHE.allowThis(f.outstandingRoyalties); FHE.allowThis(totalNetworkRoyalties);
        FHE.allow(f.totalRoyaltiesPaid, franchisee);
        FHE.allowTransient(r.royaltyDue, owner());
        emit RoyaltySettled(franchisee, reportIdx);
    }

    function updateRoyaltyRate(address franchisee, externalEuint8 calldata encRate, bytes calldata inputProof)
        external onlyOwner
    {
        franchisees[franchisee].royaltyRateBps = FHE.fromExternal(encRate, inputProof);
        FHE.allowThis(franchisees[franchisee].royaltyRateBps);
        FHE.allow(franchisees[franchisee].royaltyRateBps, franchisee);
        emit RoyaltyRateUpdated(franchisee);
    }
}
