// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateFractionalArtOwnership
/// @notice Fine art fractional ownership: encrypted artwork valuation, encrypted share splits,
///         and private artwork insurance with encrypted claim amounts.
contract PrivateFractionalArtOwnership is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Artwork {
        string artist;
        string title;
        string ipfsImage;
        uint256 totalShares;
        euint64 appraisedValueUSD;    // encrypted appraised value
        euint64 insuranceValueUSD;    // encrypted insured value
        euint64 insurancePremiumBps;  // encrypted annual premium
        euint64 accruedInsuranceCost; // encrypted cumulative premium
        uint256 acquisitionDate;
        uint256 lastReappraisalDate;
        bool active;
    }

    struct ShareHolder {
        euint64 sharesOwned;           // encrypted shares
        euint64 valueEntitlement;      // encrypted USD value of shares
        euint64 dividendsEarned;       // encrypted dividends from exhibitions
        bool registered;
    }

    struct InsuranceClaim {
        uint256 artworkId;
        euint64 claimedDamageUSD;     // encrypted damage claim
        euint64 approvedPayoutUSD;    // encrypted approved amount
        string incidentDescription;
        bool resolved;
    }

    mapping(uint256 => Artwork) private artworks;
    mapping(uint256 => mapping(address => ShareHolder)) private shareHolders;
    mapping(uint256 => InsuranceClaim) private claims;
    mapping(address => bool) public isArtAdvisor;
    mapping(address => bool) public isInsuranceAdjuster;
    uint256 public artworkCount;
    uint256 public claimCount;
    euint64 private _totalPortfolioValue;

    event ArtworkRegistered(uint256 indexed id, string title, string artist);
    event SharesPurchased(uint256 indexed artworkId, address buyer);
    event ArtworkReappraised(uint256 indexed id);
    event ClaimSubmitted(uint256 indexed claimId, uint256 artworkId);
    event ClaimResolved(uint256 indexed claimId);
    event ExhibitionDividendDistributed(uint256 indexed artworkId);

    constructor() Ownable(msg.sender) {
        _totalPortfolioValue = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioValue);
        isArtAdvisor[msg.sender] = true;
        isInsuranceAdjuster[msg.sender] = true;
    }

    function addAdvisor(address a) external onlyOwner { isArtAdvisor[a] = true; }
    function addAdjuster(address a) external onlyOwner { isInsuranceAdjuster[a] = true; }

    function registerArtwork(
        string calldata artist, string calldata title, string calldata ipfs,
        uint256 totalShares,
        externalEuint64 encAppraisalValue, bytes calldata avProof,
        externalEuint64 encInsuranceValue, bytes calldata ivProof,
        externalEuint64 encPremium, bytes calldata pProof
    ) external returns (uint256 id) {
        require(isArtAdvisor[msg.sender], "Not advisor");
        euint64 appraised = FHE.fromExternal(encAppraisalValue, avProof);
        euint64 insured = FHE.fromExternal(encInsuranceValue, ivProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        id = artworkCount++;
        artworks[id].artist = artist;
        artworks[id].title = title;
        artworks[id].ipfsImage = ipfs;
        artworks[id].totalShares = totalShares;
        artworks[id].appraisedValueUSD = appraised;
        artworks[id].insuranceValueUSD = insured;
        artworks[id].insurancePremiumBps = premium;
        artworks[id].accruedInsuranceCost = FHE.asEuint64(0);
        artworks[id].acquisitionDate = block.timestamp;
        artworks[id].lastReappraisalDate = block.timestamp;
        artworks[id].active = true;
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, appraised);
        FHE.allowThis(artworks[id].appraisedValueUSD);
        FHE.allowThis(artworks[id].insuranceValueUSD);
        FHE.allowThis(artworks[id].insurancePremiumBps);
        FHE.allowThis(artworks[id].accruedInsuranceCost);
        FHE.allowThis(_totalPortfolioValue);
        emit ArtworkRegistered(id, title, artist);
    }

    function purchaseShares(uint256 artworkId, externalEuint64 encShares, bytes calldata proof) external nonReentrant {
        Artwork storage a = artworks[artworkId];
        require(a.active, "Artwork not active");
        euint64 shares = FHE.fromExternal(encShares, proof);
        ShareHolder storage sh = shareHolders[artworkId][msg.sender];
        if (!sh.registered) {
            shareHolders[artworkId][msg.sender] = ShareHolder({
                sharesOwned: FHE.asEuint64(0), valueEntitlement: FHE.asEuint64(0),
                dividendsEarned: FHE.asEuint64(0), registered: true
            });
            FHE.allowThis(shareHolders[artworkId][msg.sender].sharesOwned);
            FHE.allowThis(shareHolders[artworkId][msg.sender].valueEntitlement);
            FHE.allowThis(shareHolders[artworkId][msg.sender].dividendsEarned);
        }
        sh.sharesOwned = FHE.add(sh.sharesOwned, shares);
        // Value entitlement = (shares / totalShares) * appraisedValue
        euint64 entitlement = FHE.div(FHE.mul(a.appraisedValueUSD, shares), uint64(a.totalShares));
        sh.valueEntitlement = FHE.add(sh.valueEntitlement, entitlement);
        FHE.allowThis(sh.sharesOwned);
        FHE.allow(sh.sharesOwned, msg.sender);
        FHE.allowThis(sh.valueEntitlement);
        FHE.allow(sh.valueEntitlement, msg.sender);
        emit SharesPurchased(artworkId, msg.sender);
    }

    function reappraise(uint256 artworkId, externalEuint64 encNewValue, bytes calldata proof) external {
        require(isArtAdvisor[msg.sender], "Not advisor");
        Artwork storage a = artworks[artworkId];
        euint64 newValue = FHE.fromExternal(encNewValue, proof);
        _totalPortfolioValue = FHE.sub(_totalPortfolioValue, a.appraisedValueUSD);
        a.appraisedValueUSD = newValue;
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, newValue);
        a.lastReappraisalDate = block.timestamp;
        FHE.allowThis(a.appraisedValueUSD);
        FHE.allowThis(_totalPortfolioValue);
        emit ArtworkReappraised(artworkId);
    }

    function submitInsuranceClaim(
        uint256 artworkId,
        externalEuint64 encDamage, bytes calldata proof,
        string calldata incident
    ) external returns (uint256 claimId) {
        require(isArtAdvisor[msg.sender], "Not advisor");
        euint64 damage = FHE.fromExternal(encDamage, proof);
        claimId = claimCount++;
        claims[claimId] = InsuranceClaim({
            artworkId: artworkId, claimedDamageUSD: damage, approvedPayoutUSD: FHE.asEuint64(0),
            incidentDescription: incident, resolved: false
        });
        FHE.allowThis(claims[claimId].claimedDamageUSD);
        FHE.allowThis(claims[claimId].approvedPayoutUSD);
        emit ClaimSubmitted(claimId, artworkId);
    }

    function resolveClaim(uint256 claimId, externalEuint64 encPayout, bytes calldata proof) external {
        require(isInsuranceAdjuster[msg.sender], "Not adjuster");
        euint64 payout = FHE.fromExternal(encPayout, proof);
        // Cap to insured value
        ebool withinInsured = FHE.le(payout, artworks[claims[claimId].artworkId].insuranceValueUSD);
        claims[claimId].approvedPayoutUSD = FHE.select(withinInsured, payout,
            artworks[claims[claimId].artworkId].insuranceValueUSD);
        claims[claimId].resolved = true;
        FHE.allowThis(claims[claimId].approvedPayoutUSD);
        FHE.allow(claims[claimId].approvedPayoutUSD, owner());
        emit ClaimResolved(claimId);
    }

    function distributeExhibitionDividend(uint256 artworkId, address[] calldata holders, externalEuint64 encTotal, bytes calldata proof) external {
        require(isArtAdvisor[msg.sender], "Not advisor");
        euint64 totalDividend = FHE.fromExternal(encTotal, proof);
        Artwork storage a = artworks[artworkId];
        for (uint256 i = 0; i < holders.length; i++) {
            ShareHolder storage sh = shareHolders[artworkId][holders[i]];
            if (!sh.registered) continue;
            euint64 holderDiv = FHE.div(FHE.mul(totalDividend, sh.sharesOwned), uint64(a.totalShares));
            sh.dividendsEarned = FHE.add(sh.dividendsEarned, holderDiv);
            FHE.allowThis(sh.dividendsEarned);
            FHE.allow(sh.dividendsEarned, holders[i]);
        }
        emit ExhibitionDividendDistributed(artworkId);
    }

    function allowArtworkDetails(uint256 artworkId, address viewer) external {
        require(isArtAdvisor[msg.sender], "Not advisor");
        FHE.allow(artworks[artworkId].appraisedValueUSD, viewer);
        FHE.allow(artworks[artworkId].insuranceValueUSD, viewer);
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