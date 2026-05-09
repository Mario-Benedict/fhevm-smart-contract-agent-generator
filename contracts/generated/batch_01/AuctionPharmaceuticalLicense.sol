// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionPharmaceuticalLicense
/// @notice Drug patent license auction where pharmaceutical companies bid encrypted
///         royalty rates and upfront fees. Licensor evaluates encrypted bids and
///         selects the highest value offer while preserving bidder confidentiality.
contract AuctionPharmaceuticalLicense is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DrugLicense {
        string drugName;
        string indication;
        euint64 minimumRoyaltyBps;  // encrypted minimum royalty rate
        euint64 minimumUpfront;     // encrypted minimum upfront payment
        uint256 auctionEnd;
        bool finalized;
        address licensee;
        euint64 winningRoyalty;
        euint64 winningUpfront;
    }

    struct PharmaCompanyBid {
        euint64 royaltyBps;     // encrypted royalty rate offered
        euint64 upfrontPayment; // encrypted upfront payment
        euint8 marketCapScore;  // encrypted: company financial strength
        bool placed;
    }

    mapping(uint256 => DrugLicense) private licenses;
    uint256 public licenseCount;
    mapping(uint256 => mapping(address => PharmaCompanyBid)) private bids;
    mapping(uint256 => address[]) private bidders;
    mapping(address => bool) public isApprovedPharma;

    event LicenseOffered(uint256 indexed id, string drugName);
    event BidSubmitted(uint256 indexed id, address indexed company);
    event LicenseAwarded(uint256 indexed id, address licensee);

    constructor() Ownable(msg.sender) {}

    function approvePharma(address company) external onlyOwner { isApprovedPharma[company] = true; }

    function offerLicense(
        string calldata drugName, string calldata indication,
        externalEuint64 encMinRoyalty, bytes calldata rProof,
        externalEuint64 encMinUpfront, bytes calldata uProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = licenseCount++;
        licenses[id].drugName = drugName;
        licenses[id].indication = indication;
        licenses[id].minimumRoyaltyBps = FHE.fromExternal(encMinRoyalty, rProof);
        licenses[id].minimumUpfront = FHE.fromExternal(encMinUpfront, uProof);
        licenses[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        licenses[id].winningRoyalty = FHE.asEuint64(0);
        licenses[id].winningUpfront = FHE.asEuint64(0);
        FHE.allowThis(licenses[id].minimumRoyaltyBps);
        FHE.allowThis(licenses[id].minimumUpfront);
        FHE.allowThis(licenses[id].winningRoyalty);
        FHE.allowThis(licenses[id].winningUpfront);
        emit LicenseOffered(id, drugName);
    }

    function submitBid(
        uint256 licenseId,
        externalEuint64 encRoyalty, bytes calldata rProof,
        externalEuint64 encUpfront, bytes calldata uProof,
        externalEuint8 encCapScore, bytes calldata cProof
    ) external nonReentrant {
        require(isApprovedPharma[msg.sender], "Not approved");
        DrugLicense storage lic = licenses[licenseId];
        require(block.timestamp < lic.auctionEnd, "Closed");
        require(!bids[licenseId][msg.sender].placed, "Already bid");
        bids[licenseId][msg.sender] = PharmaCompanyBid({
            royaltyBps: FHE.fromExternal(encRoyalty, rProof),
            upfrontPayment: FHE.fromExternal(encUpfront, uProof),
            marketCapScore: FHE.fromExternal(encCapScore, cProof),
            placed: true
        });
        FHE.allowThis(bids[licenseId][msg.sender].royaltyBps);
        FHE.allowThis(bids[licenseId][msg.sender].upfrontPayment);
        FHE.allowThis(bids[licenseId][msg.sender].marketCapScore);
        bidders[licenseId].push(msg.sender);
        emit BidSubmitted(licenseId, msg.sender);
    }

    function awardLicense(uint256 licenseId) external onlyOwner nonReentrant {
        DrugLicense storage lic = licenses[licenseId];
        require(block.timestamp >= lic.auctionEnd, "Not ended");
        require(!lic.finalized, "Finalized");
        lic.finalized = true;
        euint64 bestValue = FHE.asEuint64(0);
        address bestBidder = address(0);
        address[] storage bs = bidders[licenseId];
        for (uint256 i = 0; i < bs.length; i++) {
            PharmaCompanyBid storage b = bids[licenseId][bs[i]];
            ebool royaltyOk = FHE.ge(b.royaltyBps, lic.minimumRoyaltyBps);
            ebool upfrontOk = FHE.ge(b.upfrontPayment, lic.minimumUpfront);
            ebool valid = FHE.and(royaltyOk, upfrontOk);
            // Total value = upfront + royaltyBps (simplified comparison)
            euint64 totalValue = FHE.add(b.upfrontPayment, b.royaltyBps);
            ebool isBest = FHE.gt(totalValue, bestValue);
            ebool winner = FHE.and(valid, isBest);
            bestValue = FHE.select(winner, totalValue, bestValue);
            if (FHE.isInitialized(winner)) {
                bestBidder = bs[i];
                lic.winningRoyalty = b.royaltyBps;
                lic.winningUpfront = b.upfrontPayment;
            }
        }
        lic.licensee = bestBidder;
        FHE.allowThis(lic.winningRoyalty);
        FHE.allowThis(lic.winningUpfront);
        if (bestBidder != address(0)) {
            FHE.allow(lic.winningRoyalty, bestBidder);
            FHE.allow(lic.winningUpfront, bestBidder);
        }
        emit LicenseAwarded(licenseId, bestBidder);
    }
}
