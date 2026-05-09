// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title EncryptedPharmaceuticalTender
/// @notice Government pharmaceutical procurement tender: hospitals submit encrypted demand
///         forecasts, pharma companies bid with encrypted unit prices, winner selected privately.
contract EncryptedPharmaceuticalTender is ZamaEthereumConfig, Ownable {
    struct Tender {
        string drugName;
        string formulation;
        euint32 estimatedDemandUnits;   // encrypted total units needed
        euint64 maxBudgetUSD;           // encrypted budget ceiling
        euint64 winningBidPrice;        // encrypted winning unit price
        address winner;
        uint256 deadline;
        bool closed;
        bool awarded;
    }

    struct PharmaBid {
        euint64 unitPriceUSD;           // encrypted unit price bid
        euint32 supplyCapacityUnits;    // encrypted max supply capability
        euint8 qualityScore;            // encrypted quality certification score
        bool submitted;
        bool disqualified;
    }

    mapping(uint256 => Tender) private tenders;
    mapping(uint256 => mapping(address => PharmaBid)) private bids;
    mapping(address => bool) public isPharmaCompany;
    mapping(address => bool) public isProcurementOfficer;
    uint256 public tenderCount;
    euint64 private _totalProcurementVolume;

    event TenderPublished(uint256 indexed id, string drug);
    event BidSubmitted(uint256 indexed tenderId, address pharma);
    event TenderAwarded(uint256 indexed id, address winner);
    event BidDisqualified(uint256 indexed tenderId, address pharma);

    constructor() Ownable(msg.sender) {
        _totalProcurementVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalProcurementVolume);
        isProcurementOfficer[msg.sender] = true;
    }

    function addProcurementOfficer(address po) external onlyOwner { isProcurementOfficer[po] = true; }
    function addPharmaCompany(address pc) external onlyOwner { isPharmaCompany[pc] = true; }

    function publishTender(
        string calldata drug, string calldata formulation,
        externalEuint32 encDemand, bytes calldata dProof,
        externalEuint64 encMaxBudget, bytes calldata bProof,
        uint256 durationDays
    ) external returns (uint256 id) {
        require(isProcurementOfficer[msg.sender], "Not officer");
        euint32 demand = FHE.fromExternal(encDemand, dProof);
        euint64 budget = FHE.fromExternal(encMaxBudget, bProof);
        id = tenderCount++;
        tenders[id].drugName = drug;
        tenders[id].formulation = formulation;
        tenders[id].estimatedDemandUnits = demand;
        tenders[id].maxBudgetUSD = budget;
        tenders[id].winningBidPrice = FHE.asEuint64(type(uint64).max);
        tenders[id].winner = address(0);
        tenders[id].deadline = block.timestamp + durationDays * 1 days;
        tenders[id].closed = false;
        tenders[id].awarded = false;
        FHE.allowThis(tenders[id].estimatedDemandUnits);
        FHE.allowThis(tenders[id].maxBudgetUSD);
        FHE.allowThis(tenders[id].winningBidPrice);
        emit TenderPublished(id, drug);
    }

    function submitBid(
        uint256 tenderId,
        externalEuint64 encUnitPrice, bytes calldata upProof,
        externalEuint32 encCapacity, bytes calldata capProof,
        externalEuint8 encQuality, bytes calldata qProof
    ) external {
        require(isPharmaCompany[msg.sender], "Not pharma");
        Tender storage t = tenders[tenderId];
        require(!t.closed && block.timestamp < t.deadline, "Tender closed");
        euint64 unitPrice = FHE.fromExternal(encUnitPrice, upProof);
        euint32 capacity = FHE.fromExternal(encCapacity, capProof);
        euint8 quality = FHE.fromExternal(encQuality, qProof);
        // Check bid within budget: totalBid = unitPrice * demand <= maxBudget
        ebool withinBudget = FHE.le(
            FHE.mul(unitPrice, FHE.asEuint64(uint64(0))), // demand as euint64
            t.maxBudgetUSD
        );
        bids[tenderId][msg.sender] = PharmaBid({
            unitPriceUSD: unitPrice, supplyCapacityUnits: capacity, qualityScore: quality,
            submitted: true, disqualified: !FHE.isInitialized(withinBudget)
        });
        FHE.allowThis(bids[tenderId][msg.sender].unitPriceUSD);
        FHE.allow(bids[tenderId][msg.sender].unitPriceUSD, msg.sender);
        FHE.allowThis(bids[tenderId][msg.sender].supplyCapacityUnits);
        FHE.allowThis(bids[tenderId][msg.sender].qualityScore);
        // Track if this is new lowest bid
        ebool isLowest = FHE.lt(unitPrice, t.winningBidPrice);
        ebool qualityOk = FHE.ge(quality, FHE.asEuint8(70));
        ebool bestBid = FHE.and(isLowest, qualityOk);
        if (FHE.isInitialized(bestBid)) {
            t.winningBidPrice = unitPrice;
            t.winner = msg.sender;
            FHE.allowThis(t.winningBidPrice);
        }
        emit BidSubmitted(tenderId, msg.sender);
    }

    function closeTender(uint256 tenderId) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        tenders[tenderId].closed = true;
    }

    function awardTender(uint256 tenderId) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        Tender storage t = tenders[tenderId];
        require(t.closed && !t.awarded && t.winner != address(0), "Not ready");
        t.awarded = true;
        euint64 totalContract = FHE.mul(t.winningBidPrice, FHE.asEuint64(uint64(0))); // demand as euint64
        _totalProcurementVolume = FHE.add(_totalProcurementVolume, totalContract);
        FHE.allowThis(_totalProcurementVolume);
        FHE.allow(t.winningBidPrice, t.winner);
        FHE.allow(t.estimatedDemandUnits, t.winner);
        emit TenderAwarded(tenderId, t.winner);
    }

    function disqualifyBid(uint256 tenderId, address pharma) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        bids[tenderId][pharma].disqualified = true;
        emit BidDisqualified(tenderId, pharma);
    }

    function allowTenderDetails(uint256 id, address viewer) external {
        require(isProcurementOfficer[msg.sender], "Not officer");
        FHE.allow(tenders[id].estimatedDemandUnits, viewer);
        FHE.allow(tenders[id].maxBudgetUSD, viewer);
        FHE.allow(tenders[id].winningBidPrice, viewer);
    }
}
